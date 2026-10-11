//
//  OCRParams.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import os

/// params.json of a model pack, written by Scripts/ocr/make_pack.py from the models' inference.yml
nonisolated struct OCRParams: Decodable, Sendable {
    struct Detection: Decodable, Sendable {
        var limitSideLen: Int?
        var channelOrder: String?
        var scale: Float?
        var mean: [Float]?
        var std: [Float]?
        var thresh: Float?
        var boxThresh: Float?
        var unclipRatio: Float?
        var maxCandidates: Int?
        var minSize: Int?
    }

    struct Recognition: Decodable, Sendable {
        var imageHeight: Int?
        var minWidth: Int?
        var maxWidth: Int?
        var channelOrder: String?
        var scale: Float?
        var mean: [Float]?
        var std: [Float]?
        var useSpaceChar: Bool?
        var batchSize: Int?
    }

    var model: String?
    var det: Detection?
    var rec: Recognition?

    static func load(from url: URL) throws -> OCRParams {
        do {
            return try JSONDecoder().decode(OCRParams.self, from: Data(contentsOf: url))
        } catch {
            throw OCRError.invalidModel("params.json: \(error.localizedDescription)")
        }
    }
}

nonisolated enum ChannelOrder: Sendable {
    case rgb
    case bgr

    init(_ string: String?) {
        self = string?.uppercased() == "RGB" ? .rgb : .bgr
    }
}

/// Normalisation applied per output channel: v = (pixel * scale - mean) / std
nonisolated struct TensorNormalization: Sendable {
    var channelOrder: ChannelOrder
    var scale: Float
    var mean: [Float]
    var std: [Float]
}

/// Resolves a params.json value, falling back to the PaddleOCR v5 default with a warning
nonisolated func ocrParam<T>(_ value: T?, _ fallback: T, _ name: String) -> T {
    if let value {
        return value
    }
    OCRLog.logger.warning("params.json has no \(name, privacy: .public), using \(String(describing: fallback), privacy: .public)")
    return fallback
}
