//
//  main.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Runs the app's OCR pipeline (symlinked sources) on one PDF page on macOS. Writes the rendered
//  page (<out>.png) and the lines (<out>.json, same format as reference.py) so the two can be
//  compared on identical pixels.
//
//  Usage: OCRHarness PACK_DIR PDF PAGE_INDEX OUT_PREFIX [TRUTH_TXT]
//  Env:   THREADS=n (default 2), WARM=1 runs once before timing
//

import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 5,
      let document = PDFDocument(url: URL(fileURLWithPath: arguments[2])),
      let pageIndex = Int(arguments[3]),
      let page = document.page(at: pageIndex) else {
    print("usage: OCRHarness PACK_DIR PDF PAGE_INDEX OUT_PREFIX [TRUTH_TXT]")
    exit(1)
}
let environment = ProcessInfo.processInfo.environment
let prefix = arguments[4]

let clock = ContinuousClock()
let renderStart = clock.now
guard let rendered = PageRenderer.render(page, longSide: PageRenderer.ocrLongSide) else {
    print("could not render page")
    exit(1)
}
let renderTime = clock.now - renderStart

if let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: prefix + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
    CGImageDestinationAddImage(destination, rendered.image, nil)
    CGImageDestinationFinalize(destination)
}

let engine = PaddleOCREngine(identifier: "harness", paths: OCRModelPaths(directory: URL(fileURLWithPath: arguments[1])), threads: Int(environment["THREADS"] ?? "2"))
if environment["WARM"] != nil {
    _ = try await engine.recognizeWithTimings(rendered.image)
}
let (lines, timings) = try await engine.recognizeWithTimings(rendered.image)

func corners(_ rect: CGRect) -> [Double] {
    [rect.minX, rect.minY, rect.maxX, rect.maxY].map { Double($0) }
}
let json: [String: Any] = [
    "width": rendered.image.width,
    "height": rendered.image.height,
    "timings": ["render": renderTime.milliseconds, "det": timings.detection.milliseconds, "rec": timings.recognition.milliseconds],
    "lines": lines.map { line -> [String: Any] in
        [
            "box": corners(line.bounds),
            "vertical": line.isVertical,
            "text": line.text,
            "confidence": Double(line.confidence),
            "glyphs": line.glyphs.map { ["c": $0.character, "r": corners($0.rect)] as [String: Any] },
        ]
    },
]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: prefix + ".json"))

let layer = OCRTextLayerBuilder.layer(from: lines, pixelToPage: rendered.pixelToPage, pageIndex: pageIndex, engine: engine.identifier)
let text = layer.lines.filter { !$0.isRuby }.map(\.text).joined()
print("render \(renderTime.milliseconds) ms, det \(timings.detection.milliseconds) ms, rec \(timings.recognition.milliseconds) ms, \(lines.count) lines, \(layer.lines.filter(\.isRuby).count) ruby, \(Set(layer.lines.map(\.blockIndex)).count) blocks")
print("reading order: \(text)")

// first glyphs in display space (page space through /Rotate), comparable between rotated and upright pages
let display = page.transform(for: .cropBox)
for glyph in layer.lines.first(where: { !$0.isRuby })?.glyphs.prefix(3) ?? [] {
    let rect = glyph.rect.applying(display)
    print("glyph \(glyph.character) at \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))")
}

if arguments.count > 5 {
    let truth = Array(try String(contentsOfFile: arguments[5], encoding: .utf8).filter { !$0.isWhitespace })
    let predicted = Array(text.filter { !$0.isWhitespace })
    var previous = Array(0...truth.count)
    for i in predicted.indices {
        var current = [i + 1]
        for j in truth.indices {
            current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (predicted[i] == truth[j] ? 0 : 1)))
        }
        previous = current
    }
    let errors = previous[truth.count]
    print(String(format: "accuracy: %.1f%% (%d errors / %d chars)", (1 - Double(errors) / Double(max(truth.count, 1))) * 100, errors, truth.count))
}
