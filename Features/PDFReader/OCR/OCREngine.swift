//
//  OCREngine.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import os

nonisolated protocol OCREngine: Sendable {
    /// Stored as PDFTextLayer.engine
    var identifier: String { get }
    /// Lines in pixel space (top-left origin)
    func recognize(_ image: CGImage) async throws -> [OCRLine]
}

nonisolated struct OCRGlyph: Sendable {
    let character: String
    let rect: CGRect
}

nonisolated struct OCRLine: Sendable {
    // axis-aligned in v1
    let bounds: CGRect
    let isVertical: Bool
    let text: String
    let confidence: Float
    let glyphs: [OCRGlyph]

    var quad: [CGPoint] {
        [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
         CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)]
    }
}

nonisolated struct OCRTimings: Sendable {
    var detection: Duration = .zero
    var recognition: Duration = .zero
    var total: Duration { detection + recognition }
}

nonisolated enum OCRError: LocalizedError {
    case modelNotInstalled
    case runtimeUnavailable
    case invalidModel(String)
    case inference(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            String(localized: "The OCR model is not installed")
        case .runtimeUnavailable:
            String(localized: "Could not start the OCR runtime")
        case .invalidModel(let message):
            String(localized: "Invalid OCR model: \(message)")
        case .inference(let message):
            String(localized: "OCR failed: \(message)")
        }
    }
}

nonisolated enum OCRLog {
    static let logger = Logger(subsystem: "de.manhhao.hoshi", category: "ocr")
}
