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

    /// The glyph a lookup starts from: the tapped glyph, or the start of the tapped word in space-separated text
    static func hitTest(_ layer: PDFTextLayer, point: CGPoint) -> PDFGlyphRef? {
        // a direct hit on furigana wins: OCR main-line boxes usually include the ruby column
        let ruby = nearestGlyph(layer, point: point, ruby: true)
        if let inside = ruby.inside, let base = baseGlyph(for: inside, in: layer) {
            return base
        }
        let main = nearestGlyph(layer, point: point, ruby: false)
        if let inside = main.inside {
            return wordStart(of: inside, in: layer)
        }
        if let nearest = main.nearest {
            return wordStart(of: nearest, in: layer)
        }
        return ruby.nearest.flatMap { baseGlyph(for: $0, in: layer) }
    }

    // Mirrors findWordStart in selection.js, within one line
    private static func wordStart(of hit: PDFGlyphRef, in layer: PDFTextLayer) -> PDFGlyphRef {
        let glyphs = layer.lines[hit.line].glyphs
        guard JapaneseText.isWordCharacter(glyphs[hit.glyph].character) else {
            return hit
        }
        var start = hit.glyph
        var index = hit.glyph
        while index > 0 {
            let character = glyphs[index - 1].character
            // an apostrophe belongs to the word only between letters (don't), not as a quote ('word)
            let inWord = JapaneseText.isWordCharacter(character) ||
                (JapaneseText.isApostrophe(character) && index > 1 && JapaneseText.isWordCharacter(glyphs[index - 2].character))
            guard inWord else {
                break
            }
            index -= 1
            if JapaneseText.isWordCharacter(character) {
                start = index
            }
        }
        return PDFGlyphRef(line: hit.line, glyph: start)
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

    private static func nearestGlyph(_ layer: PDFTextLayer, point: CGPoint, ruby: Bool) -> (inside: PDFGlyphRef?, nearest: PDFGlyphRef?) {
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
        return (inside?.ref, nearest?.ref)
    }

    /// First glyph of the base text under the tapped ruby run, so a furigana tap looks up the whole word
    private static func baseGlyph(for rubyRef: PDFGlyphRef, in layer: PDFTextLayer) -> PDFGlyphRef? {
        let ruby = layer.lines[rubyRef.line]
        let vertical = ruby.isVertical
        // along-axis extent of the run around the tapped glyph; one OCR line can hold several runs
        let maxGap = ruby.thickness
        var first = rubyRef.glyph
        var last = rubyRef.glyph
        while first > 0, gap(ruby.glyphs[first - 1].rect, ruby.glyphs[first].rect, vertical: vertical) < maxGap {
            first -= 1
        }
        while last < ruby.glyphs.count - 1, gap(ruby.glyphs[last].rect, ruby.glyphs[last + 1].rect, vertical: vertical) < maxGap {
            last += 1
        }
        let run = ruby.glyphs[first...last].dropFirst().reduce(ruby.glyphs[first].rect) { $0.union($1.rect) }
        let runRange = vertical ? run.minY...run.maxY : run.minX...run.maxX

        // ruby goes right of vertical lines and above horizontal ones; the base line is the closest on that side
        var base: (index: Int, distance: CGFloat)?
        for (lineIndex, line) in layer.lines.enumerated() where !line.isRuby && line.blockIndex == ruby.blockIndex {
            let lineRange = vertical ? line.bounds.minY...line.bounds.maxY : line.bounds.minX...line.bounds.maxX
            guard lineRange.overlaps(runRange) else {
                continue
            }
            let distance = vertical ? run.midX - line.bounds.midX : run.midY - line.bounds.midY
            guard distance > 0, base == nil || distance < base!.distance else {
                continue
            }
            base = (lineIndex, distance)
        }
        guard let base else {
            return nil
        }
        // OCR ruby boxes drift along the line, so anchor on the base glyph nearest the run's center and
        // extend back over the kanji it covers
        let glyphs = layer.lines[base.index].glyphs
        func along(_ rect: CGRect) -> ClosedRange<CGFloat> {
            vertical ? rect.minY...rect.maxY : rect.minX...rect.maxX
        }
        let center = vertical ? run.midY : run.midX
        func offset(_ index: Int) -> CGFloat {
            abs((vertical ? glyphs[index].rect.midY : glyphs[index].rect.midX) - center)
        }
        guard let anchor = glyphs.indices.min(by: { offset($0) < offset($1) }) else {
            return nil
        }
        guard isKanji(glyphs[anchor].character) else {
            let first = glyphs.indices.first {
                runRange.overlaps(along(glyphs[$0].rect)) && !JapaneseText.isScanBoundary(glyphs[$0].character, scanNonJapaneseText: true)
            }
            return PDFGlyphRef(line: base.index, glyph: first ?? anchor)
        }
        var start = anchor
        while start > 0 {
            let previous = along(glyphs[start - 1].rect)
            let margin = 0.5 * (previous.upperBound - previous.lowerBound)
            let reach = (runRange.lowerBound - margin)...(runRange.upperBound + margin)
            guard isKanji(glyphs[start - 1].character), reach.overlaps(previous) else {
                break
            }
            start -= 1
        }
        return PDFGlyphRef(line: base.index, glyph: start)
    }

    private static func isKanji(_ character: String) -> Bool {
        character.unicodeScalars.first?.properties.isIdeographic ?? false
    }

    // along the reading axis, between consecutive glyphs
    private static func gap(_ a: CGRect, _ b: CGRect, vertical: Bool) -> CGFloat {
        vertical ? max(a.minY - b.maxY, b.minY - a.maxY) : max(b.minX - a.maxX, a.minX - b.maxX)
    }
}
