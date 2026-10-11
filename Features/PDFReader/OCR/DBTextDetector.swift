//
//  DBTextDetector.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import OnnxRuntimeBindings

nonisolated struct DBConfig: Sendable {
    // fallbacks are the PaddleOCR v5 defaults, params.json overrides them
    var limitSideLen = 1536
    var normalization = TensorNormalization(channelOrder: .bgr, scale: 1 / 255, mean: [0.485, 0.456, 0.406], std: [0.229, 0.224, 0.225])
    var thresh: Float = 0.3
    var boxThresh: Float = 0.6
    var unclipRatio: Float = 1.6
    var maxCandidates = 300
    var minSize = 3

    init() {}

    init(params: OCRParams.Detection?) {
        let p = params ?? OCRParams.Detection()
        limitSideLen = ocrParam(p.limitSideLen, limitSideLen, "det.limitSideLen")
        normalization = TensorNormalization(
            channelOrder: ChannelOrder(ocrParam(p.channelOrder, "BGR", "det.channelOrder")),
            scale: ocrParam(p.scale, normalization.scale, "det.scale"),
            mean: ocrParam(p.mean, normalization.mean, "det.mean"),
            std: ocrParam(p.std, normalization.std, "det.std")
        )
        thresh = ocrParam(p.thresh, thresh, "det.thresh")
        boxThresh = ocrParam(p.boxThresh, boxThresh, "det.boxThresh")
        unclipRatio = ocrParam(p.unclipRatio, unclipRatio, "det.unclipRatio")
        maxCandidates = min(ocrParam(p.maxCandidates, maxCandidates, "det.maxCandidates"), 300)
        minSize = ocrParam(p.minSize, minSize, "det.minSize")
    }
}

nonisolated struct DetectedBox: Sendable {
    /// rendered image pixels, top-left origin
    let rect: CGRect
    let score: Float
}

/// Probability map of the DB detection model
nonisolated struct ProbabilityMap: Sendable {
    let width: Int
    let height: Int
    let values: [Float]
}

nonisolated struct DBTextDetector {
    let session: ORTSession
    let inputName: String
    let outputName: String
    let runOptions: ORTRunOptions?
    let config: DBConfig

    func detect(_ image: PixelImage) throws -> [DetectedBox] {
        let (map, scaleX, scaleY) = try probabilityMap(image)
        return Self.boxes(in: map, config: config, scaleX: scaleX, scaleY: scaleY, imageWidth: image.width, imageHeight: image.height)
    }

    /// Runs the model; `scaleX`/`scaleY` map probability map pixels back to image pixels
    func probabilityMap(_ image: PixelImage) throws -> (map: ProbabilityMap, scaleX: Double, scaleY: Double) {
        let (width, height) = Self.inputSize(width: image.width, height: image.height, limitSideLen: config.limitSideLen)
        let resized = image.resized(width: width, height: height)

        let count = 3 * width * height
        guard let data = NSMutableData(length: count * MemoryLayout<Float>.size) else {
            throw OCRError.inference("out of memory")
        }
        resized.writeTensor(to: data.mutableBytes.assumingMemoryBound(to: Float.self), rowStride: width, planeHeight: height, normalization: config.normalization)
        let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, 3, NSNumber(value: height), NSNumber(value: width)])
        let outputs = try session.run(withInputs: [inputName: input], outputNames: [outputName], runOptions: runOptions)
        guard let output = outputs[outputName] else {
            throw OCRError.inference("det produced no output")
        }
        let shape = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
        guard shape.count == 4, shape[0] == 1, shape[1] == 1 else {
            throw OCRError.invalidModel("det output shape \(shape), expected [1, 1, H, W]")
        }
        let mapHeight = shape[2]
        let mapWidth = shape[3]
        let outputData = try output.tensorData() as Data
        let values = outputData.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(mapWidth * mapHeight)) }
        let map = ProbabilityMap(width: mapWidth, height: mapHeight, values: values)
        return (map, Double(image.width) / Double(mapWidth), Double(image.height) / Double(mapHeight))
    }

    /// Long side ≤ limit (never upscaled), both sides rounded to multiples of 32
    static func inputSize(width: Int, height: Int, limitSideLen: Int) -> (width: Int, height: Int) {
        let ratio = min(1, Double(limitSideLen) / Double(max(width, height)))
        let roundTo32 = { (value: Int) -> Int in
            max(32, Int((Double(value) * ratio / 32).rounded(.toNearestOrEven)) * 32)
        }
        return (roundTo32(width), roundTo32(height))
    }

    /// DB post-processing with axis-aligned boxes: threshold, 8-connected components, score, unclip
    static func boxes(in map: ProbabilityMap, config: DBConfig, scaleX: Double, scaleY: Double, imageWidth: Int, imageHeight: Int) -> [DetectedBox] {
        let width = map.width
        let height = map.height
        let probabilities = map.values
        var visited = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        var boxes: [DetectedBox] = []

        for start in 0..<(width * height) where !visited[start] && probabilities[start] > config.thresh {
            visited[start] = true
            stack.append(start)
            var minX = start % width, maxX = minX
            var minY = start / width, maxY = minY
            while let index = stack.popLast() {
                let x = index % width
                let y = index / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) {
                        let neighbour = ny * width + nx
                        if !visited[neighbour] && probabilities[neighbour] > config.thresh {
                            visited[neighbour] = true
                            stack.append(neighbour)
                        }
                    }
                }
            }

            let boxWidth = maxX - minX + 1
            let boxHeight = maxY - minY + 1
            guard min(boxWidth, boxHeight) >= config.minSize else {
                continue
            }
            // PaddleOCR's "fast" score: mean probability inside the box
            var sum: Float = 0
            for y in minY...maxY {
                for x in minX...maxX {
                    sum += probabilities[y * width + x]
                }
            }
            let score = sum / Float(boxWidth * boxHeight)
            guard score >= config.boxThresh else {
                continue
            }
            // DB shrinks text regions during training, grow them back
            let distance = Double(boxWidth * boxHeight) * Double(config.unclipRatio) / Double(2 * (boxWidth + boxHeight))
            guard Double(min(boxWidth, boxHeight)) + 2 * distance >= Double(config.minSize + 2) else {
                continue
            }
            let x0 = max(0, (Double(minX) - distance) * scaleX)
            let y0 = max(0, (Double(minY) - distance) * scaleY)
            let x1 = min(Double(imageWidth), (Double(maxX + 1) + distance) * scaleX)
            let y1 = min(Double(imageHeight), (Double(maxY + 1) + distance) * scaleY)
            boxes.append(DetectedBox(rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), score: score))
            if boxes.count >= config.maxCandidates {
                break
            }
        }
        return boxes
    }
}
