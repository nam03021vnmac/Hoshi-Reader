//
//  EmbeddedTextQuality.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics

nonisolated enum EmbeddedTextQuality {
    static let minGlyphs = 8
    static let minKnownFraction = 0.85
    static let maxBrokenFraction = 0.02
    static let minInsideFraction = 0.9
    static let minCoverage: CGFloat = 0.01

    static func isUsable(_ layer: PDFTextLayer, pageBounds: CGRect) -> Bool {
        let glyphs = layer.lines.flatMap(\.glyphs)
        guard glyphs.count >= minGlyphs, pageBounds.width > 0, pageBounds.height > 0 else {
            return false
        }
        let total = Double(glyphs.count)

        var known = 0
        var broken = 0
        var inside = 0
        var area: CGFloat = 0
        for glyph in glyphs {
            let value = glyph.character.unicodeScalars.first?.value ?? 0
            if isKnown(value) {
                known += 1
            }
            if value == 0xfffd || (0xe000...0xf8ff).contains(value) {
                broken += 1
            }
            if pageBounds.contains(CGPoint(x: glyph.rect.midX, y: glyph.rect.midY)) {
                inside += 1
            }
            area += glyph.rect.width * glyph.rect.height
        }

        return Double(known) / total >= minKnownFraction
            && Double(broken) / total <= maxBrokenFraction
            && Double(inside) / total >= minInsideFraction
            && area / (pageBounds.width * pageBounds.height) >= minCoverage
    }

    private static func isKnown(_ value: UInt32) -> Bool {
        JapaneseText.isCodePointJapanese(value)
            || (0x21...0x7e).contains(value)
            || (0x2000...0x206f).contains(value) // general punctuation
            || value == 0xb7
    }
}
