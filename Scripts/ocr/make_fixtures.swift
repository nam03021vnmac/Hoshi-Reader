//
//  make_fixtures.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Generates the scanned (image-only) tategaki PDF fixtures used to validate OCR.
//  Text is public domain (夏目漱石「吾輩は猫である」, 芥川龍之介「羅生門」, Aozora Bunko).
//
//  Usage: swift Scripts/ocr/make_fixtures.swift Tests/Fixtures/pdf
//

import AppKit
import CoreText
import Foundation
import PDFKit

let dpi: CGFloat = 300
let pagePoints = CGSize(width: 297.64, height: 419.53) // A6
let pagePixels = CGSize(width: (pagePoints.width / 72 * dpi).rounded(), height: (pagePoints.height / 72 * dpi).rounded())
let fontName = "HiraMinProN-W3" as CFString

let neko1 = "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。吾輩はここで始めて人間というものを見た。しかもあとで聞くとそれは書生という人間中で一番獰悪な種族であったそうだ。この書生というのは時々我々を捕えて煮て食うという話である。しかしその当時は何という考もなかったから別段恐しいとも思わなかった。"
let neko2 = "ただ彼の掌に載せられてスーと持ち上げられた時何だかフワフワした感じがあったばかりである。掌の上で少し落ちついて書生の顔を見たのがいわゆる人間というものの見始であろう。この時妙なものだと思った感じが今でも残っている。第一毛をもって装飾されべきはずの顔がつるつるしてまるで薬缶だ。その後猫にもだいぶ逢ったがこんな片輪には一度も出会わした事がない。"

// (base, ruby) segments; ruby is nil for plain text
let rashomon: [(String, String?)] = [
    ("ある日の暮方の事である。一人の", nil), ("下人", "げにん"), ("が、", nil), ("羅生門", "らしょうもん"),
    ("の下で雨やみを待っていた。広い門の下には、この男のほかに誰もいない。ただ、所々", nil), ("丹塗", "にぬり"),
    ("の剥げた、大きな", nil), ("円柱", "まるばしら"), ("に、", nil), ("蟋蟀", "きりぎりす"),
    ("が一匹とまっている。羅生門が、", nil), ("朱雀大路", "すざくおおじ"),
    ("にある以上は、この男のほかにも、雨やみをする", nil), ("市女笠", "いちめがさ"), ("や", nil), ("揉烏帽子", "もみえぼし"),
    ("が、もう二三人はありそうなものである。それが、この男のほかには誰もいない。何故かと云うと、この二三年、京都には、地震とか辻風とか火事とか饑饉とか云う災がつづいて起った。そこで洛中のさびれ方は一通りではない。", nil),
]
let tierTop = "旧記によると、仏像や仏具を打砕いて、その丹がついたり、金銀の箔がついたりした木を、路ばたにつみ重ねて、薪の料に売っていたと云う事である。洛中がその始末であるから、羅生門の修理などは、元より誰も捨てて顧る者がなかった。"
let tierBottom = "するとその荒れ果てたのをよい事にして、狐狸が棲む。盗人が棲む。とうとうしまいには、引取り手のない死人を、この門へ持って来て、棄てて行くと云う習慣さえ出来た。そこで、日の目が見えなくなると、誰でも気味を悪るがって、この門の近所へは足ぶみをしない事になってしまったのである。"

func attributed(_ segments: [(String, String?)], fontSize: CGFloat) -> NSAttributedString {
    let font = CTFontCreateWithName(fontName, fontSize, nil)
    let result = NSMutableAttributedString()
    for (base, ruby) in segments {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String): true,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1),
        ]
        if let ruby {
            let rubyAttributes: [CFString: Any] = [kCTRubyAnnotationSizeFactorAttributeName: 0.5]
            let annotation = CTRubyAnnotationCreateWithAttributes(.center, .auto, .before, ruby as CFString, rubyAttributes as CFDictionary)
            attributes[NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)] = annotation
        }
        result.append(NSAttributedString(string: base, attributes: attributes))
    }
    return result
}

func drawVertical(_ text: NSAttributedString, in rect: CGRect, context: CGContext) -> Int {
    let framesetter = CTFramesetterCreateWithAttributedString(text)
    let frameAttributes = [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), frameAttributes)
    CTFrameDraw(frame, context)
    return CTFrameGetVisibleStringRange(frame).length
}

struct PageSpec {
    var blocks: [(NSAttributedString, CGRect)]
    var noise: Bool = false
    var skewDegrees: CGFloat = 0
}

func renderPage(_ spec: PageSpec) -> (CGImage, String) {
    let width = Int(pagePixels.width)
    let height = Int(pagePixels.height)
    let background = CGColor(gray: spec.noise ? 0.96 : 1, alpha: 1)
    func makeContext() -> CGContext {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
    let context = makeContext()
    var truth = ""
    for (text, rect) in spec.blocks {
        let visible = drawVertical(text, in: rect, context: context)
        if visible < text.length {
            fatalError("text overflows its frame (\(visible)/\(text.length)): \(text.string.prefix(10))")
        }
        truth += text.string
    }
    var image = context.makeImage()!
    // skew the finished bitmap: CoreText lays vertical frames out horizontally under a rotated CTM
    if spec.skewDegrees != 0 {
        let skewed = makeContext()
        skewed.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        skewed.rotate(by: spec.skewDegrees * .pi / 180)
        skewed.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        skewed.interpolationQuality = .high
        skewed.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        image = skewed.makeImage()!
    }
    if spec.noise {
        image = addNoise(image)
    }
    return (image, truth)
}

// deterministic speckle noise and a slight blur, like a cheap scanner
func addNoise(_ image: CGImage) -> CGImage {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var seed: UInt64 = 0x5eed
    func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed >> 33
    }
    var blurred = pixels
    for y in 1..<(height - 1) {
        for x in 1..<(width - 1) {
            let i = y * width + x
            let sum = Int(pixels[i]) * 4 + Int(pixels[i - 1]) + Int(pixels[i + 1]) + Int(pixels[i - width]) + Int(pixels[i + width])
            blurred[i] = UInt8(sum / 8)
        }
    }
    for i in blurred.indices {
        let r = next() % 1000
        if r < 2 {
            blurred[i] = UInt8(next() % 90)
        } else {
            let jitter = Int(next() % 9) - 4
            blurred[i] = UInt8(max(0, min(255, Int(blurred[i]) + jitter)))
        }
    }
    let out = CGContext(data: &blurred, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    return out.makeImage()!
}

func jpegImage(_ image: CGImage) -> CGImage {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])!
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

func writePDF(_ images: [CGImage], to url: URL, rotate: Bool = false) {
    var mediaBox = rotate
        ? CGRect(x: 0, y: 0, width: pagePoints.height, height: pagePoints.width)
        : CGRect(origin: .zero, size: pagePoints)
    let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
    for image in images {
        context.beginPDFPage(nil)
        if rotate {
            // store the page turned 90° counter-clockwise; /Rotate 90 displays it upright
            context.translateBy(x: mediaBox.width, y: 0)
            context.rotate(by: .pi / 2)
            context.draw(jpegImage(image), in: CGRect(origin: .zero, size: pagePoints))
        } else {
            context.draw(jpegImage(image), in: mediaBox)
        }
        context.endPDFPage()
    }
    context.closePDF()
    if rotate, let document = PDFDocument(url: url) {
        for index in 0..<document.pageCount {
            document.page(at: index)?.rotation = 90
        }
        document.write(to: url)
    }
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures/pdf")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let fontSize = 9 / 72 * dpi
let margin: CGFloat = 120
let body = CGRect(x: margin, y: margin, width: pagePixels.width - 2 * margin, height: pagePixels.height - 2 * margin)

func save(_ name: String, _ specs: [PageSpec], rotate: Bool = false) {
    var images: [CGImage] = []
    for (index, spec) in specs.enumerated() {
        let (image, truth) = renderPage(spec)
        images.append(image)
        try! (truth + "\n").write(to: outDir.appendingPathComponent("\(name).p\(index + 1).txt"), atomically: true, encoding: .utf8)
    }
    writePDF(images, to: outDir.appendingPathComponent("\(name).pdf"), rotate: rotate)
    print("wrote \(name).pdf (\(specs.count) pages)")
}

let plain1 = PageSpec(blocks: [(attributed([(neko1, nil)], fontSize: fontSize), body)])
let plain2 = PageSpec(blocks: [(attributed([(neko2, nil)], fontSize: fontSize), body)])
save("scan_vertical", [plain1, plain2])
save("scan_rotated", [plain1], rotate: true)

let denseSize = 8 / 72 * dpi
let ruby = PageSpec(blocks: [(attributed(rashomon, fontSize: denseSize), body)], noise: true, skewDegrees: 0.4)
let tierGap: CGFloat = 60
let tierHeight = (body.height - tierGap) / 2
let tiers = PageSpec(blocks: [
    (attributed([(tierTop, nil)], fontSize: denseSize), CGRect(x: body.minX, y: body.minY + tierHeight + tierGap, width: body.width, height: tierHeight)),
    (attributed([(tierBottom, nil)], fontSize: denseSize), CGRect(x: body.minX, y: body.minY, width: body.width, height: tierHeight)),
], noise: true, skewDegrees: -0.3)
save("scan_vertical_dense", [ruby, tiers])
