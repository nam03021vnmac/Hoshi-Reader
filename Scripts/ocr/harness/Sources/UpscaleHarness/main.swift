//
//  main.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Checks the app's upscaling pipeline (symlinked sources) on macOS. It can't prove anything about
//  the iPhone's Neural Engine, PDFKit's alignment or memory limits; those need a device.
//
//  Usage: UpscaleHarness [EXPORT_DIR]
//         EXPORT_DIR is the output of Scripts/upscale/export_coreml.py, default Scripts/upscale/build.
//         Exits non-zero if a check fails.
//

import CoreGraphics
import CoreML
import Foundation
import ImageIO

var failures = 0

func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    let suffix = detail()
    print("\(passed ? "PASS" : "FAIL")  \(name)\(suffix.isEmpty ? "" : "  (\(suffix))")")
    if !passed {
        failures += 1
    }
}

struct NearestModel: UpscaleTileModel {
    let inputSize: Int
    let scale: Int

    func run(input: UnsafePointer<UInt8>, output: UnsafeMutablePointer<UInt8>) throws {
        let outputSize = inputSize * scale
        for y in 0..<outputSize {
            for x in 0..<outputSize {
                let from = ((y / scale) * inputSize + x / scale) * 4
                let to = (y * outputSize + x) * 4
                for channel in 0..<4 {
                    output[to + channel] = input[from + channel]
                }
            }
        }
    }
}

struct BrokenModel: UpscaleTileModel {
    let outputSize: Int

    func run(input: UnsafePointer<UInt8>, output: UnsafeMutablePointer<UInt8>) throws {
        memset(output, 0, outputSize * outputSize * 4)
    }
}

/// xorshift, so failures reproduce
struct Generator {
    var state: UInt64 = 0x9E3779B97F4A7C15

    mutating func next() -> UInt8 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return UInt8(truncatingIfNeeded: state >> 32)
    }
}

func noiseBitmap(width: Int, height: Int) -> UpscaleBitmap {
    var generator = Generator()
    var bitmap = UpscaleBitmap(width: width, height: height)
    for index in 0..<(width * height) {
        bitmap.pixels[index * 4] = generator.next()
        bitmap.pixels[index * 4 + 1] = generator.next()
        bitmap.pixels[index * 4 + 2] = generator.next()
    }
    return bitmap
}

/// Dot tone, stripes and diagonal strokes
func mangaBitmap(width: Int, height: Int, shift: Int = 0) -> UpscaleBitmap {
    var bitmap = UpscaleBitmap(width: width, height: height)
    for y in 0..<height {
        for x in 0..<width {
            let px = x + shift
            let py = y + shift
            var value = 255
            if py % 300 < 150 {
                if (px + py) % 6 < 2 && (px - py + 6000) % 6 < 2 {
                    value = 30
                }
            } else if (px + py) % 7 < 2 {
                value = 60
            }
            if Swift.abs(py - px / 2 - 40) % 170 < 3 {
                value = 0
            }
            let offset = (y * width + x) * 4
            bitmap.pixels[offset] = UInt8(value)
            bitmap.pixels[offset + 1] = UInt8(value)
            bitmap.pixels[offset + 2] = UInt8(value)
        }
    }
    return bitmap
}

func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var total = 0.0
    for index in a.indices {
        let difference = Double(a[index]) - Double(b[index])
        total += difference * difference
    }
    let mean = total / Double(a.count)
    return mean == 0 ? .infinity : 10 * log10(255 * 255 / mean)
}

// MARK: tiling

func checkGeometry() {
    let tiler = UpscaleTiler.animeV3
    let model = NearestModel(inputSize: tiler.inputSize, scale: tiler.scale)
    let sizes = [(1, 1), (7, 300), (100, 80), (219, 219), (220, 220), (221, 221), (256, 256), (257, 900), (440, 441), (1000, 1400)]

    for (width, height) in sizes {
        let source = noiseBitmap(width: width, height: height)
        do {
            let output = try tiler.upscale(source, model: model)
            var exact = output.width == width * 2 && output.height == height * 2
            if exact {
                outer: for y in 0..<output.height {
                    for x in 0..<output.width {
                        let from = ((y / 2) * width + x / 2) * 4
                        let to = (y * output.width + x) * 4
                        if output.pixels[to] != source.pixels[from] || output.pixels[to + 1] != source.pixels[from + 1] || output.pixels[to + 2] != source.pixels[from + 2] {
                            exact = false
                            break outer
                        }
                    }
                }
            }
            check("geometry \(width)x\(height) matches a nearest resize", exact)
        } catch {
            check("geometry \(width)x\(height)", false, "\(error)")
        }
    }

    // every core has its full context inside the window
    var contained = true
    var covered = 0
    for tile in tiler.tiles(width: 1000, height: 1400) {
        let left = tile.coreX - tile.originX
        let top = tile.coreY - tile.originY
        contained = contained && left >= tiler.padding && top >= tiler.padding
        contained = contained && tiler.inputSize - left - tile.coreWidth >= tiler.padding
        contained = contained && tiler.inputSize - top - tile.coreHeight >= tiler.padding
        contained = contained && tile.originX >= -tiler.padding && tile.originY >= -tiler.padding
        covered += tile.coreWidth * tile.coreHeight
    }
    check("cores keep their padding and cover the page once", contained && covered == 1000 * 1400)
    check("a 1000x1400 page takes 35 tiles", tiler.tiles(width: 1000, height: 1400).count == 35)
    check("the largest input takes at most 70 tiles", tiler.tiles(width: 1448, height: 2048).count <= 70)

    do {
        _ = try tiler.upscale(noiseBitmap(width: 300, height: 300), model: BrokenModel(outputSize: tiler.inputSize * tiler.scale))
        check("broken model output is rejected", false)
    } catch UpscaleError.corruptOutput {
        check("broken model output is rejected", true)
    } catch {
        check("broken model output is rejected", false, "\(error)")
    }
}

// MARK: monochrome

func checkMonochrome() {
    let page = mangaBitmap(width: 800, height: 1100)
    check("grey page is neutral", MonochromeGuard.isNeutral(page))

    var noisy = page
    for index in stride(from: 1000, to: 800 * 1100, by: 2900) {
        let offset = index * 4
        let value = Int(noisy.pixels[offset + 1])
        noisy.pixels[offset] = UInt8(value >= 128 ? value - 5 : value + 5)
    }
    check("sparse weak chroma noise is still neutral", MonochromeGuard.isNeutral(noisy))

    var panel = page
    for y in 500..<520 {
        for x in 400..<430 {
            let offset = (y * 800 + x) * 4
            panel.pixels[offset] = 220
            panel.pixels[offset + 1] = 40
            panel.pixels[offset + 2] = 40
        }
    }
    check("a small colored panel is not neutral", !MonochromeGuard.isNeutral(panel))

    var tinted = page
    for index in 0..<(800 * 1100) {
        tinted.pixels[index * 4] = tinted.pixels[index * 4 + 1] &+ (tinted.pixels[index * 4 + 1] < 250 ? 5 : 0)
    }
    check("an evenly tinted page is not neutral", !MonochromeGuard.isNeutral(tinted))

    // half grey, half red source; the output has invented chroma on the grey side and washed out color on the other
    var colorSource = UpscaleBitmap(width: 40, height: 20)
    for y in 0..<20 {
        for x in 0..<40 {
            let offset = (y * 40 + x) * 4
            let red = x >= 20
            colorSource.pixels[offset] = red ? 200 : 128
            colorSource.pixels[offset + 1] = red ? 40 : 128
            colorSource.pixels[offset + 2] = red ? 40 : 128
        }
    }
    var colorOutput = UpscaleBitmap(width: 80, height: 40)
    for y in 0..<40 {
        for x in 0..<80 {
            let offset = (y * 80 + x) * 4
            let red = x >= 40
            colorOutput.pixels[offset] = red ? 150 : 150
            colorOutput.pixels[offset + 1] = red ? 70 : 120
            colorOutput.pixels[offset + 2] = red ? 70 : 140
        }
    }
    let lumaBefore = (77 * 150 + 150 * 120 + 29 * 140 + 128) >> 8
    MonochromeGuard.restoreColor(&colorOutput, source: colorSource)
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let offset = (y * 80 + x) * 4
        return (Int(colorOutput.pixels[offset]), Int(colorOutput.pixels[offset + 1]), Int(colorOutput.pixels[offset + 2]))
    }
    var greyClean = true
    for y in 0..<40 {
        for x in 0..<36 {
            let value = pixel(x, y)
            greyClean = greyClean && value.0 == value.1 && value.1 == value.2 && value.0 == lumaBefore
        }
    }
    check("invented chroma is gone from the grey part of a color page", greyClean, "\(pixel(5, 5)) expected \(lumaBefore)")
    let redSide = pixel(70, 20)
    check("real color comes from the source", redSide.0 - redSide.1 == 160 && redSide.1 == redSide.2, "\(redSide)")
    var edgesCovered = true
    for point in [(0, 0), (79, 0), (0, 39), (79, 39)] {
        let value = pixel(point.0, point.1)
        edgesCovered = edgesCovered && (point.0 == 0 ? value.0 == value.1 : value.0 - value.1 == 160)
    }
    check("the page's edges and corners are handled", edgesCovered)

    var fringed = page
    fringed.pixels[0] = 200
    fringed.pixels[1] = 10
    fringed.pixels[2] = 90
    MonochromeGuard.makeNeutral(&fringed)
    check("makeNeutral removes chroma", fringed.pixels[0] == fringed.pixels[1] && fringed.pixels[1] == fringed.pixels[2])
}

// MARK: probe

func solidImage(width: Int, height: Int, gray: UInt8 = 128) -> CGImage {
    let pixels = [UInt8](repeating: gray, count: width * height * 4)
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func makePDF(size: CGSize, rotation: Int = 0, draw: (CGContext) -> Void) -> CGPDFDocument {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    let consumer = CGDataConsumer(data: data)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
    draw(context)
    context.endPDFPage()
    context.closePDF()
    return CGPDFDocument(CGDataProvider(data: data as CFData)!)!
}

func checkProbe() {
    let page = CGSize(width: 500, height: 700)
    let screen: CGFloat = 2796
    func decision(_ pdf: CGPDFDocument, pageLongSide: CGFloat = 700) -> (PageRasterInfo, UpscalePolicy.Decision) {
        let info = PageResolutionProbe.probe(pdf.page(at: 1)!)
        return (info, UpscalePolicy.decide(info, pageLongSide: pageLongSide, screenLongSide: screen))
    }

    let raster = makePDF(size: page) { $0.draw(solidImage(width: 1000, height: 1400), in: CGRect(origin: .zero, size: page)) }
    var result = decision(raster)
    check("full page raster", result.0.coverage > 0.99 && Swift.abs(result.0.pixelsPerPoint - 2) < 0.01 && result.1 == .upscale(inputLongSide: 1400), "\(result)")

    let vector = makePDF(size: page) { context in
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 10, y: 10, width: 400, height: 600))
    }
    result = decision(vector)
    check("vector page is skipped", result.1 == .skip(.notRaster), "\(result)")

    let cropped = makePDF(size: page) { $0.draw(solidImage(width: 1500, height: 2100), in: CGRect(x: -250, y: -350, width: 1000, height: 1400)) }
    result = decision(cropped)
    check("cropped placement uses placed resolution", result.0.coverage > 0.99 && Swift.abs(result.0.pixelsPerPoint - 1.5) < 0.01 && result.1 == .upscale(inputLongSide: 1050), "\(result)")

    let strips = makePDF(size: page) { context in
        for index in 0..<7 {
            context.draw(solidImage(width: 1000, height: 200), in: CGRect(x: 0, y: CGFloat(index) * 100, width: 500, height: 100))
        }
    }
    result = decision(strips)
    check("strips add up to full coverage", result.0.coverage > 0.99 && Swift.abs(result.0.pixelsPerPoint - 2) < 0.01, "\(result)")

    let partial = makePDF(size: page) { $0.draw(solidImage(width: 500, height: 700), in: CGRect(x: 0, y: 0, width: 250, height: 700)) }
    result = decision(partial)
    check("half page image is skipped", result.1 == .skip(.notRaster), "\(result)")

    let sharp = makePDF(size: page) { $0.draw(solidImage(width: 2000, height: 2800), in: CGRect(origin: .zero, size: page)) }
    result = decision(sharp)
    check("source at screen resolution is skipped", result.1 == .skip(.sharpEnough), "\(result)")

    let large = makePDF(size: CGSize(width: 500, height: 700)) { $0.draw(solidImage(width: 1900, height: 2660), in: CGRect(origin: .zero, size: page)) }
    let largeInfo = PageResolutionProbe.probe(large.page(at: 1)!)
    check("input is capped for a large screen", UpscalePolicy.decide(largeInfo, pageLongSide: 700, screenLongSide: 4000) == .upscale(inputLongSide: 2048))

    let nested = makePDF(size: page) { context in
        context.drawPDFPage(raster.page(at: 1)!)
    }
    result = decision(nested)
    check("image inside a form is found", result.0.coverage > 0.99 && Swift.abs(result.0.pixelsPerPoint - 2) < 0.01, "\(result)")

    // no JBIG2 encoder here, so a stencil mask over a low resolution background stands in for that layout
    let maskBits = [UInt8](repeating: 0xAA, count: 125 * 1400)
    let mask = CGImage(maskWidth: 1000, height: 1400, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: 125, provider: CGDataProvider(data: Data(maskBits) as CFData)!, decode: nil, shouldInterpolate: false)!
    let layered = makePDF(size: page) { context in
        context.draw(solidImage(width: 250, height: 350), in: CGRect(origin: .zero, size: page))
        context.setFillColor(gray: 0, alpha: 1)
        context.draw(mask, in: CGRect(origin: .zero, size: page))
    }
    result = decision(layered)
    check("stencil mask over a background is skipped", result.1 == .skip(.bitonal), "\(result)")
}

// MARK: codec

func checkCodec() {
    let page = mangaBitmap(width: 2000, height: 2800)
    guard let gray = page.makeGrayImage(), let color = page.makeImage() else {
        check("codec images", false)
        return
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let reference = (0..<(2000 * 2800)).map { page.pixels[$0 * 4] }
    func measure(_ label: String, data: Data?, format: UpscaleCodec.Format) -> Double {
        guard let data else {
            print("      \(label): no encoder")
            return -1
        }
        let url = directory.appendingPathComponent("\(label).\(format.rawValue)")
        try? data.write(to: url)
        let start = Date()
        guard let decoded = UpscaleCodec.decode(url), let bitmap = UpscaleBitmap(image: decoded) else {
            print("      \(label): can't decode")
            return -1
        }
        let elapsed = Date().timeIntervalSince(start)
        let values = (0..<(2000 * 2800)).map { bitmap.pixels[$0 * 4] }
        let score = psnr(reference, values)
        print(String(format: "      %@: %.2f MB, %.1f dB, decode %.0f ms", label, Double(data.count) / 1_000_000, score, elapsed * 1000))
        return score
    }
    let lossless = measure("grey-png", data: UpscaleCodec.encode(gray, as: .png), format: .png)
    _ = measure("grey-heic-0.9", data: UpscaleCodec.encode(gray, as: .heic), format: .heic)
    _ = measure("rgb-heic-0.9", data: UpscaleCodec.encode(color, as: .heic), format: .heic)
    check("grey PNG round trips exactly", lossless == .infinity)

    let url = directory.appendingPathComponent("thumb.png")
    try? UpscaleCodec.encode(gray, as: .png)?.write(to: url)
    let thumbnail = UpscaleCodec.decode(url, maxLongSide: 1000)
    check("decode honours maxLongSide", thumbnail.map { max($0.width, $0.height) == 1000 } ?? false)
}

// MARK: model

func compile(_ package: URL) -> URL? {
    do {
        let start = Date()
        let url = try MLModel.compileModel(at: package)
        print(String(format: "      compiled in %.0f ms", Date().timeIntervalSince(start) * 1000))
        return url
    } catch {
        check("compile model", false, "\(error)")
        return nil
    }
}

func checkModel(directory: URL) async {
    let package = directory.appendingPathComponent("RealESRGANAnimeV3x2.mlpackage")
    guard FileManager.default.fileExists(atPath: package.path) else {
        check("exported model exists at \(package.path)", false)
        return
    }
    guard let compiled = compile(package) else {
        return
    }
    let tiler = UpscaleTiler.animeV3
    let model: CoreMLTileModel
    do {
        model = try CoreMLTileModel(url: compiled, inputSize: tiler.inputSize, outputSize: tiler.inputSize * tiler.scale)
    } catch {
        check("load model", false, "\(error)")
        return
    }
    if let share = await CoreMLTileModel.neuralEngineShare(url: compiled) {
        print(String(format: "      Neural Engine share of ops on this Mac: %.0f%%", share * 100))
    } else {
        print("      no compute plan available")
    }

    // the same tile as the PyTorch reference, through the app's own model wrapper
    func loadRGBX(_ url: URL) -> UpscaleBitmap? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return UpscaleBitmap(image: image)
    }
    if let input = loadRGBX(directory.appendingPathComponent("reference/input.png")),
       let expected = loadRGBX(directory.appendingPathComponent("reference/pytorch.png")) {
        var bgra = input.pixels
        for index in 0..<(input.width * input.height) {
            bgra.swapAt(index * 4, index * 4 + 2)
        }
        var output = [UInt8](repeating: 0, count: expected.pixels.count)
        do {
            try model.run(input: bgra, output: &output)
            var worst = 0
            var total = 0
            for index in 0..<(expected.width * expected.height) {
                let difference = Swift.abs(Int(output[index * 4 + 1]) - Int(expected.pixels[index * 4 + 1]))
                worst = max(worst, difference)
                total += difference
            }
            let mean = Double(total) / Double(expected.width * expected.height)
            check("tile matches the PyTorch reference", worst <= 2, String(format: "max %d, mean %.3f", worst, mean))
        } catch {
            check("tile matches the PyTorch reference", false, "\(error)")
        }
    } else {
        check("reference images exist", false)
    }

    // shifting the page moves the tile grid; a visible seam would change the output there
    do {
        let width = 900
        let height = 1100
        let shift = 110
        let first = mangaBitmap(width: width, height: height)
        let second = mangaBitmap(width: width - shift, height: height - shift, shift: shift)
        func compare(_ tiler: UpscaleTiler) throws -> (worst: Int, over: Int) {
            let a = try tiler.upscale(first, model: model)
            let b = try tiler.upscale(second, model: model)
            var worst = 0
            var over = 0
            // stay away from the pages' true edges, where the context really does differ
            let margin = (UpscaleTiler.animeV3.padding + 2) * tiler.scale
            for y in margin..<(b.height - margin) {
                for x in margin..<(b.width - margin) {
                    let difference = Swift.abs(Int(a.pixels[((y + shift * 2) * a.width + x + shift * 2) * 4 + 1]) - Int(b.pixels[(y * b.width + x) * 4 + 1]))
                    worst = max(worst, difference)
                    if difference > 2 {
                        over += 1
                    }
                }
            }
            return (worst, over)
        }
        let result = try compare(tiler)
        check("moving the tile grid changes output by at most 2 LSB", result.worst <= 2, "max \(result.worst), \(result.over) pixels over")
        // without this the check above could be passing because it can't see seams
        let control = try compare(UpscaleTiler(inputSize: tiler.inputSize, padding: 2, scale: tiler.scale))
        check("control: too little padding does show seams", control.over > 0, "max \(control.worst), \(control.over) pixels over")
        
        let start = Date()
        var output = try tiler.upscale(first, model: model)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "      %dx%d took %.2f s on this Mac (%d tiles)", width, height, elapsed, tiler.tiles(width: width, height: height).count))
        
        var chroma = 0
        for index in 0..<(output.width * output.height) {
            let red = output.pixels[index * 4]
            let green = output.pixels[index * 4 + 1]
            let blue = output.pixels[index * 4 + 2]
            chroma = max(chroma, Int(max(red, green, blue)) - Int(min(red, green, blue)))
        }
        print("      chroma the model invents on a neutral page: \(chroma)")
        MonochromeGuard.makeNeutral(&output)
        checkOutputCodec(output)
    } catch {
        check("seam comparison", false, "\(error)")
    }
}

/// On real model output, which compresses nothing like the synthetic pattern does
func checkOutputCodec(_ output: UpscaleBitmap) {
    guard let gray = output.makeGrayImage(), let color = output.makeImage() else {
        check("output codec images", false)
        return
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let pixels = output.width * output.height
    let reference = (0..<pixels).map { output.pixels[$0 * 4] }
    for (label, data, format) in [("grey-png", UpscaleCodec.encode(gray, as: .png), UpscaleCodec.Format.png), ("rgb-heic-0.9", UpscaleCodec.encode(color, as: .heic), .heic), ("rgb-png", UpscaleCodec.encode(color, as: .png), .png)] {
        guard let data else {
            print("      \(label): no encoder")
            continue
        }
        let url = directory.appendingPathComponent("\(label).\(format.rawValue)")
        try? data.write(to: url)
        let start = Date()
        guard let decoded = UpscaleCodec.decode(url), let bitmap = UpscaleBitmap(image: decoded) else {
            print("      \(label): can't decode")
            continue
        }
        let elapsed = Date().timeIntervalSince(start)
        let score = psnr(reference, (0..<pixels).map { bitmap.pixels[$0 * 4] })
        print(String(format: "      output %@: %.2f MB, %.1f dB, decode %.0f ms", label, Double(data.count) / 1_000_000, score, elapsed * 1000))
    }
}

// MARK: entry

let arguments = CommandLine.arguments
let export = arguments.count > 1
    ? URL(fileURLWithPath: arguments[1])
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../upscale/build").standardizedFileURL

checkGeometry()
checkMonochrome()
checkProbe()
checkCodec()
await checkModel(directory: export)

print(failures == 0 ? "All checks passed" : "\(failures) checks failed")
exit(failures == 0 ? 0 : 1)
