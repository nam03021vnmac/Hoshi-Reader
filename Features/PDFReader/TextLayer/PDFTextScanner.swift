//
//  PDFTextScanner.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics

nonisolated struct PDFGlyphRef: Hashable, Sendable {
    let line: Int
    let glyph: Int
}

nonisolated struct PDFScanResult: Sendable {
    let text: String
    let glyphs: [PDFGlyphRef]
    let sentence: String
    let clozeOffset: Int
    let firstGlyphRect: CGRect
    let isVertical: Bool
}

// Mirrors selectText in selection.js
nonisolated enum PDFTextScanner {
    private static let sentenceWindow = 500

    static func hitTest(_ layer: PDFTextLayer, point: CGPoint) -> PDFGlyphRef? {
        if let hit = nearestGlyph(layer, point: point, ruby: false) {
            return hit
        }
        guard let rubyHit = nearestGlyph(layer, point: point, ruby: true) else {
            return nil
        }
        return baseGlyph(for: rubyHit, in: layer)
    }

    static func scan(_ layer: PDFTextLayer, from hit: PDFGlyphRef, maxLength: Int, scanNonJapaneseText: Bool) -> PDFScanResult? {
        guard layer.lines.indices.contains(hit.line), layer.lines[hit.line].glyphs.indices.contains(hit.glyph) else {
            return nil
        }
        let hitLine = layer.lines[hit.line]
        guard !JapaneseText.isScanBoundary(hitLine.glyphs[hit.glyph].character, scanNonJapaneseText: scanNonJapaneseText) else {
            return nil
        }

        var refs: [PDFGlyphRef] = []
        var text = ""
        var lineIndex = hit.line
        var glyphIndex = hit.glyph
        scanning: while refs.count < maxLength {
            let glyphs = layer.lines[lineIndex].glyphs
            while glyphIndex < glyphs.count, refs.count < maxLength {
                let character = glyphs[glyphIndex].character
                if JapaneseText.isScanBoundary(character, scanNonJapaneseText: scanNonJapaneseText) {
                    break scanning
                }
                text += character
                refs.append(PDFGlyphRef(line: lineIndex, glyph: glyphIndex))
                glyphIndex += 1
            }
            guard glyphIndex >= glyphs.count,
                  let next = nextMainLine(after: lineIndex, in: layer),
                  layer.lines[next].blockIndex == hitLine.blockIndex else {
                break
            }
            lineIndex = next
            glyphIndex = 0
        }
        guard !refs.isEmpty else {
            return nil
        }

        var parts: [String] = []
        var hitPosition = 0
        for (index, line) in layer.lines.enumerated() where !line.isRuby && line.blockIndex == hitLine.blockIndex {
            if index == hit.line {
                hitPosition = parts.count + hit.glyph
            }
            parts.append(contentsOf: line.glyphs.map(\.character))
        }
        let lower = max(0, hitPosition - sentenceWindow)
        let upper = min(parts.count, hitPosition + sentenceWindow)
        let (sentence, clozeOffset) = JapaneseText.sentence(in: Array(parts[lower..<upper]), at: hitPosition - lower)

        return PDFScanResult(
            text: text,
            glyphs: refs,
            sentence: sentence,
            clozeOffset: clozeOffset,
            firstGlyphRect: hitLine.glyphs[hit.glyph].rect,
            isVertical: hitLine.isVertical
        )
    }

    private static func nextMainLine(after index: Int, in layer: PDFTextLayer) -> Int? {
        var next = index + 1
        while next < layer.lines.count {
            if !layer.lines[next].isRuby {
                return next
            }
            next += 1
        }
        return nil
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func nearestGlyph(_ layer: PDFTextLayer, point: CGPoint, ruby: Bool) -> PDFGlyphRef? {
        var inside: (ref: PDFGlyphRef, distance: CGFloat)?
        var nearest: (ref: PDFGlyphRef, distance: CGFloat)?

        for (lineIndex, line) in layer.lines.enumerated() where line.isRuby == ruby {
            let thickness = line.thickness
            let reach = 0.5 * thickness
            guard line.bounds.insetBy(dx: -reach, dy: -reach).contains(point) else {
                continue
            }
            for (glyphIndex, glyph) in line.glyphs.enumerated() {
                let ref = PDFGlyphRef(line: lineIndex, glyph: glyphIndex)
                let centerDistance = hypot(glyph.rect.midX - point.x, glyph.rect.midY - point.y)
                if glyph.rect.insetBy(dx: -0.1 * thickness, dy: -0.1 * thickness).contains(point) {
                    if inside == nil || centerDistance < inside!.distance {
                        inside = (ref, centerDistance)
                    }
                    continue
                }
                let edgeDistance = distance(from: point, to: glyph.rect)
                if edgeDistance <= reach, nearest == nil || edgeDistance < nearest!.distance {
                    nearest = (ref, edgeDistance)
                }
            }
        }
        return inside?.ref ?? nearest?.ref
    }

    private static func baseGlyph(for rubyRef: PDFGlyphRef, in layer: PDFTextLayer) -> PDFGlyphRef? {
        let ruby = layer.lines[rubyRef.line]
        let center = CGPoint(x: ruby.glyphs[rubyRef.glyph].rect.midX, y: ruby.glyphs[rubyRef.glyph].rect.midY)
        var best: (ref: PDFGlyphRef, distance: CGFloat)?
        for (lineIndex, line) in layer.lines.enumerated() where !line.isRuby && line.blockIndex == ruby.blockIndex {
            for (glyphIndex, glyph) in line.glyphs.enumerated() {
                let d = distance(from: center, to: glyph.rect)
                if best == nil || d < best!.distance {
                    best = (PDFGlyphRef(line: lineIndex, glyph: glyphIndex), d)
                }
            }
        }
        return best?.ref
    }
}
