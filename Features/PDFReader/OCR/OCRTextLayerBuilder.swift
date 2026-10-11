//
//  OCRTextLayerBuilder.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics

nonisolated enum OCRTextLayerBuilder {
    /// Maps OCR lines (rendered image pixels) into page space and orders them for reading
    static func layer(from lines: [OCRLine], pixelToPage: CGAffineTransform, pageIndex: Int, engine: String) -> PDFTextLayer {
        let textLines = lines.compactMap { line -> PDFTextLine? in
            let glyphs = line.glyphs.map { PDFGlyph(character: $0.character, rect: $0.rect.applying(pixelToPage)) }
            return glyphs.isEmpty ? nil : PDFTextLine(isVertical: line.isVertical, glyphs: glyphs)
        }
        let ordered = LayoutAnalyzer.analyze(textLines)
        return PDFTextLayer(pageIndex: pageIndex, source: ordered.isEmpty ? .empty : .ocr, engine: engine, lines: ordered)
    }
}
