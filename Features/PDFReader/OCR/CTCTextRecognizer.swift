//
//  CTCTextRecognizer.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import OnnxRuntimeBindings

nonisolated struct CTCConfig: Sendable {
    // fallbacks are the PaddleOCR v5 defaults, params.json overrides them
    var imageHeight = 48
    var minWidth = 320
    var maxWidth = 3200
    var normalization = TensorNormalization(channelOrder: .bgr, scale: 1 / 255, mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5])
    var useSpaceChar: Bool?
    var batchSize = 6
    // caps batch size × padded width, the rec output is N × T × ~18k floats
    var maxBatchWidth = 4096
    var minConfidence: Float = 0.5

    init() {}

    init(params: OCRParams.Recognition?) {
        let p = params ?? OCRParams.Recognition()
        imageHeight = ocrParam(p.imageHeight, imageHeight, "rec.imageHeight")
        minWidth = ocrParam(p.minWidth, minWidth, "rec.minWidth")
        maxWidth = ocrParam(p.maxWidth, maxWidth, "rec.maxWidth")
        normalization = TensorNormalization(
            channelOrder: ChannelOrder(ocrParam(p.channelOrder, "BGR", "rec.channelOrder")),
            scale: ocrParam(p.scale, normalization.scale, "rec.scale"),
            mean: ocrParam(p.mean, normalization.mean, "rec.mean"),
            std: ocrParam(p.std, normalization.std, "rec.std")
        )
        useSpaceChar = p.useSpaceChar
        batchSize = max(1, ocrParam(p.batchSize, batchSize, "rec.batchSize"))
    }
}

/// Best class per timestep
nonisolated struct CTCStep: Sendable, Equatable {
    let index: Int
    let probability: Float
}

nonisolated struct DecodedCharacter: Sendable, Equatable {
    let character: String
    /// first and last timestep of the character's (collapsed) run
    let start: Int
    let end: Int
    let probability: Float
}

nonisolated struct CTCTextRecognizer {
    let session: ORTSession
    let inputName: String
    let outputName: String
    let runOptions: ORTRunOptions?
    let config: CTCConfig
    let dictionary: [String]

    private struct Crop {
        let index: Int
        let rect: CGRect      // integer pixel rect in the rendered image
        let isVertical: Bool
        let strip: PixelImage
        let resizedWidth: Int
    }

    func recognize(_ image: PixelImage, boxes: [DetectedBox]) throws -> [OCRLine] {
        var crops: [Crop] = []
        for (index, box) in boxes.enumerated() {
            let x0 = Int(box.rect.minX.rounded(.down))
            let y0 = Int(box.rect.minY.rounded(.down))
            let x1 = Int(box.rect.maxX.rounded(.up))
            let y1 = Int(box.rect.maxY.rounded(.up))
            guard x1 - x0 >= 1, y1 - y0 >= 1 else {
                continue
            }
            let crop = image.cropped(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            // tategaki: turn the column so the top of the column is the left of the strip, like PaddleOCR
            let isVertical = Double(crop.height) >= 1.5 * Double(crop.width)
            let strip = isVertical ? crop.rotatedCounterClockwise() : crop
            let resizedWidth = max(1, min(Int((Double(config.imageHeight) * Double(strip.width) / Double(strip.height)).rounded(.up)), config.maxWidth))
            crops.append(Crop(index: index, rect: CGRect(x: x0, y: y0, width: crop.width, height: crop.height), isVertical: isVertical, strip: strip, resizedWidth: resizedWidth))
        }

        let order = crops.indices.sorted {
            Double(crops[$0].strip.width) / Double(crops[$0].strip.height) < Double(crops[$1].strip.width) / Double(crops[$1].strip.height)
        }
        var lines = [OCRLine?](repeating: nil, count: crops.count)
        for batch in Self.batches(order.map { crops[$0].resizedWidth }, config: config) {
            let members = batch.map { order[$0] }
            let paddedWidth = Self.paddedWidth(members.map { crops[$0].resizedWidth }, config: config)
            let (rows, classes) = try run(members.map { crops[$0] }, paddedWidth: paddedWidth)
            try checkClasses(classes)
            for (row, cropIndex) in members.enumerated() {
                lines[cropIndex] = line(for: crops[cropIndex], steps: rows[row], classes: classes, paddedWidth: paddedWidth)
            }
        }
        return lines.compactMap { $0 }
    }

    /// Groups positions in the aspect-sorted order into batches
    static func batches(_ resizedWidths: [Int], config: CTCConfig) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for (position, width) in resizedWidths.enumerated() {
            let widths = current.map { resizedWidths[$0] } + [width]
            if !current.isEmpty && (current.count == config.batchSize || widths.count * paddedWidth(widths, config: config) > config.maxBatchWidth) {
                result.append(current)
                current = []
            }
            current.append(position)
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    static func paddedWidth(_ resizedWidths: [Int], config: CTCConfig) -> Int {
        let widest = resizedWidths.max() ?? config.minWidth
        return min(max(config.minWidth, (widest + 7) / 8 * 8), config.maxWidth)
    }

    /// Runs one batch and reduces each row to its per-timestep argmax while the output buffer is alive
    private func run(_ batch: [Crop], paddedWidth: Int) throws -> (rows: [[CTCStep]], classes: Int) {
        let height = config.imageHeight
        let itemSize = 3 * height * paddedWidth
        // zero padding after normalisation
        guard let data = NSMutableData(length: batch.count * itemSize * MemoryLayout<Float>.size) else {
            throw OCRError.inference("out of memory")
        }
        let floats = data.mutableBytes.assumingMemoryBound(to: Float.self)
        for (row, crop) in batch.enumerated() {
            let resized = crop.strip.resized(width: crop.resizedWidth, height: height)
            resized.writeTensor(to: floats + row * itemSize, rowStride: paddedWidth, planeHeight: height, normalization: config.normalization)
        }
        let input = try ORTValue(tensorData: data, elementType: .float, shape: [NSNumber(value: batch.count), 3, NSNumber(value: height), NSNumber(value: paddedWidth)])
        let outputs = try session.run(withInputs: [inputName: input], outputNames: [outputName], runOptions: runOptions)
        guard let output = outputs[outputName] else {
            throw OCRError.inference("rec produced no output")
        }
        let shape = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
        guard shape.count == 3, shape[0] == batch.count else {
            throw OCRError.invalidModel("rec output shape \(shape), expected [N, T, C]")
        }
        let steps = shape[1]
        let classes = shape[2]
        // the data is owned by `output`, which outlives this use
        let outputData = try output.tensorData()
        let probabilities = UnsafeBufferPointer(start: outputData.mutableBytes.assumingMemoryBound(to: Float.self), count: shape[0] * steps * classes)
        let rows = (0..<batch.count).map { row in
            Self.argmax(UnsafeBufferPointer(rebasing: probabilities[(row * steps * classes)..<((row + 1) * steps * classes)]), steps: steps, classes: classes)
        }
        withExtendedLifetime(output) {}
        return (rows, classes)
    }

    /// The rec output has a blank class at index 0 and, with use_space_char, a space class at the end
    private func checkClasses(_ classes: Int) throws {
        guard classes == dictionary.count + 1 || classes == dictionary.count + 2 else {
            throw OCRError.invalidModel("rec has \(classes) classes but dict.txt has \(dictionary.count) entries")
        }
        if let useSpaceChar = config.useSpaceChar, useSpaceChar != (classes == dictionary.count + 2) {
            throw OCRError.invalidModel("params.json useSpaceChar doesn't match the rec model")
        }
    }

    private func line(for crop: Crop, steps: [CTCStep], classes: Int, paddedWidth: Int) -> OCRLine? {
        // ignore timesteps that only saw padding
        let validSteps = min(steps.count, Int((Double(steps.count) * Double(crop.resizedWidth) / Double(paddedWidth)).rounded(.up)))
        let characters = Self.decode(steps.prefix(validSteps), classes: classes, dictionary: dictionary, useSpaceChar: classes == dictionary.count + 2)
        guard !characters.isEmpty else {
            return nil
        }
        let confidence = characters.reduce(0) { $0 + $1.probability } / Float(characters.count)
        let text = characters.map(\.character).joined()
        guard confidence >= config.minConfidence, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }

        let stride = Double(paddedWidth) / Double(steps.count)
        let spans = Self.glyphSpans(characters, stride: stride, validWidth: Double(crop.resizedWidth))
        // strip pixels -> crop pixels along the reading axis
        let along = crop.isVertical ? crop.rect.height : crop.rect.width
        let factor = along / CGFloat(crop.resizedWidth)
        var glyphs: [OCRGlyph] = []
        for (decoded, span) in zip(characters, spans) where decoded.character != " " {
            let start = CGFloat(span.lowerBound) * factor
            let end = CGFloat(span.upperBound) * factor
            let rect = crop.isVertical
                ? CGRect(x: crop.rect.minX, y: crop.rect.minY + start, width: crop.rect.width, height: end - start)
                : CGRect(x: crop.rect.minX + start, y: crop.rect.minY, width: end - start, height: crop.rect.height)
            // a lone combining mark belongs to the previous glyph
            if let last = glyphs.last, decoded.character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .enclosingMark }) {
                glyphs[glyphs.count - 1] = OCRGlyph(character: last.character + decoded.character, rect: last.rect.union(rect))
            } else {
                glyphs.append(OCRGlyph(character: decoded.character, rect: rect))
            }
        }
        guard !glyphs.isEmpty else {
            return nil
        }
        return OCRLine(bounds: crop.rect, isVertical: crop.isVertical, text: text, confidence: confidence, glyphs: glyphs)
    }

    static func argmax(_ probabilities: UnsafeBufferPointer<Float>, steps: Int, classes: Int) -> [CTCStep] {
        (0..<steps).map { t in
            var best = 0
            var bestProbability = probabilities[t * classes]
            for k in 1..<classes where probabilities[t * classes + k] > bestProbability {
                best = k
                bestProbability = probabilities[t * classes + k]
            }
            return CTCStep(index: best, probability: bestProbability)
        }
    }

    /// Greedy CTC decoding: collapse repeats, drop blanks (class 0), map class i to dictionary[i - 1]
    static func decode(_ steps: some Collection<CTCStep>, classes: Int, dictionary: [String], useSpaceChar: Bool) -> [DecodedCharacter] {
        var result: [DecodedCharacter] = []
        var previous = 0
        for (t, step) in steps.enumerated() {
            let best = step.index
            if best != 0 && best == previous, let last = result.last {
                result[result.count - 1] = DecodedCharacter(character: last.character, start: last.start, end: t, probability: last.probability)
            } else if best != 0 {
                let character: String
                if useSpaceChar && best == classes - 1 {
                    character = " "
                } else if best - 1 < dictionary.count {
                    character = dictionary[best - 1]
                } else {
                    character = ""
                }
                result.append(DecodedCharacter(character: character, start: t, end: t, probability: step.probability))
            }
            previous = best
        }
        return result.filter { !$0.character.isEmpty }
    }

    /// Strip x-range of each character, from CTC peak positions
    static func glyphSpans(_ characters: [DecodedCharacter], stride: Double, validWidth: Double) -> [ClosedRange<Double>] {
        let centers = characters.map { Double($0.start + $0.end + 1) / 2 * stride }
        guard centers.count > 1 else {
            return centers.isEmpty ? [] : [0...validWidth]
        }
        let gaps = zip(centers.dropFirst(), centers).map { $0 - $1 }.sorted()
        let spacing = gaps.count % 2 == 1 ? gaps[gaps.count / 2] : (gaps[gaps.count / 2 - 1] + gaps[gaps.count / 2]) / 2
        let first = max(0, centers[0] - spacing / 2)
        let last = max(first, min(validWidth, centers[centers.count - 1] + spacing / 2))
        // Japanese is close to fixed pitch, equal cells beat raw CTC peaks
        if characters.allSatisfy({ isFullwidth($0.character) }) {
            let cell = (last - first) / Double(centers.count)
            return centers.indices.map { first + Double($0) * cell...first + Double($0 + 1) * cell }
        }
        var bounds = [first]
        for i in 0..<(centers.count - 1) {
            bounds.append(min(max((centers[i] + centers[i + 1]) / 2, bounds[bounds.count - 1]), last))
        }
        bounds.append(last)
        return centers.indices.map { bounds[$0]...bounds[$0 + 1] }
    }

    static func isFullwidth(_ character: String) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else {
            return false
        }
        if (0xFF61...0xFF9F).contains(scalar) {
            return false
        }
        return scalar >= 0x2E80 || (0x3000...0x30FF).contains(scalar)
    }
}
