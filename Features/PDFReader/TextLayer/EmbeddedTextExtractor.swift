//
//  EmbeddedTextExtractor.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit

nonisolated enum EmbeddedTextExtractor {
    static let engine = "pdfkit"

    static func extract(page: PDFPage, pageIndex: Int) -> PDFTextLayer? {
        guard let string = page.string, !string.isEmpty else {
            return nil
        }

        let nsString = string as NSString
        var glyphs: [PDFGlyph] = []
        var seen: Set<String> = []
        var builder = LineBuilder()
        nsString.enumerateSubstrings(in: NSRange(location: 0, length: nsString.length), options: .byComposedCharacterSequences) { substring, range, _, _ in
            guard let substring else {
                return
            }
            if substring.allSatisfy({ $0.isWhitespace || $0.isNewline }) {
                builder.flush()
                return
            }
            // characterBounds is the glyph's ink box and unreliable for vertical text, the selection box is the full cell
            var rect = page.selection(for: range)?.bounds(for: page) ?? .zero
            if rect.isEmpty || rect.isNull {
                // characterBounds takes a UTF-16 index into page.string
                rect = page.characterBounds(at: range.location)
            }
            guard rect.width > 0, rect.height > 0,
                  rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else {
                return
            }
            // text drawn twice at the same spot (fake bold)
            guard seen.insert("\(substring)\(Int(rect.minX.rounded()))\(Int(rect.minY.rounded()))").inserted else {
                return
            }
            let glyph = PDFGlyph(character: substring, rect: rect)
            glyphs.append(glyph)
            builder.append(glyph)
        }
        builder.flush()
        
        // PDFKit's string order isn't reliable for vertical text, so prefer geometry and fall back to string order
        let raw = GeometricLines.build(glyphs) ?? builder.lines
        let lines = LayoutAnalyzer.analyze(raw)
        guard !lines.isEmpty else {
            return nil
        }
        return PDFTextLayer(pageIndex: pageIndex, source: .embedded, engine: engine, lines: lines)
    }

    private enum Orientation {
        case horizontal
        case vertical
    }

    private struct LineBuilder {
        var lines: [PDFTextLine] = []
        private var glyphs: [PDFGlyph] = []
        private var orientation: Orientation?

        mutating func append(_ glyph: PDFGlyph) {
            guard let last = glyphs.last else {
                glyphs = [glyph]
                return
            }
            let candidates: [Orientation] = orientation.map { [$0] } ?? [.horizontal, .vertical]
            let dx = abs(glyph.rect.midX - last.rect.midX)
            let dy = abs(glyph.rect.midY - last.rect.midY)
            let ordered = dx >= dy ? candidates : candidates.reversed()
            for candidate in ordered where Self.isAdjacent(last.rect, glyph.rect, candidate) {
                orientation = candidate
                glyphs.append(glyph)
                return
            }
            flush()
            glyphs = [glyph]
        }

        mutating func flush() {
            guard !glyphs.isEmpty else {
                return
            }
            lines.append(PDFTextLine(isVertical: orientation == .vertical, glyphs: glyphs))
            glyphs = []
            orientation = nil
        }

        private static func isAdjacent(_ last: CGRect, _ next: CGRect, _ orientation: Orientation) -> Bool {
            let size = max(last.width, last.height)
            let gap: CGFloat
            let overlap: CGFloat
            let minCross: CGFloat
            switch orientation {
            case .horizontal:
                guard next.midX > last.midX else {
                    return false
                }
                gap = next.minX - last.maxX
                overlap = min(last.maxY, next.maxY) - max(last.minY, next.minY)
                minCross = min(last.height, next.height)
            case .vertical:
                guard next.midY < last.midY else {
                    return false
                }
                gap = last.minY - next.maxY
                overlap = min(last.maxX, next.maxX) - max(last.minX, next.minX)
                minCross = min(last.width, next.width)
            }
            let cross = orientation == .vertical ? (last.width, next.width) : (last.height, next.height)
            guard GeometricLines.isSimilarSize(cross.0, cross.1) else {
                return false
            }
            return gap < 1.5 * size && gap > -0.6 * size && overlap > 0.5 * minCross
        }
    }
}

nonisolated enum GeometricLines {
    private static let maxGlyphs = 4000
    
    /// Returns nil when the reading direction can't be told apart.
    static func build(_ glyphs: [PDFGlyph]) -> [PDFTextLine]? {
        guard glyphs.count >= 2, glyphs.count <= maxGlyphs else {
            return nil
        }
        let sizes = glyphs.map { max($0.rect.width, $0.rect.height) }.sorted()
        let size = sizes[sizes.count / 2]
        
        let horizontalGap = medianGap(glyphs, vertical: false, size: size)
        let verticalGap = medianGap(glyphs, vertical: true, size: size)
        let vertical: Bool
        switch (horizontalGap, verticalGap) {
        case (nil, nil):
            return nil
        case (nil, _?):
            vertical = true
        case (_?, nil):
            vertical = false
        case let (h?, v?):
            guard abs(h - v) > 0.1 * size else {
                return nil
            }
            vertical = v < h
        }
        
        var lines = chains(glyphs, vertical: vertical).map { PDFTextLine(isVertical: vertical, glyphs: $0) }
        // leftovers (e.g. a horizontal running head on a vertical page) get a second pass the other way
        let singles = lines.filter { $0.glyphs.count == 1 }.flatMap(\.glyphs)
        if singles.count >= 2 {
            let second = chains(singles, vertical: !vertical).filter { $0.count > 1 }
            let used = Set(second.flatMap { $0 }.map(\.rect))
            lines = lines.filter { $0.glyphs.count > 1 }
                + second.map { PDFTextLine(isVertical: !vertical, glyphs: $0) }
                + singles.filter { !used.contains($0.rect) }.map { PDFTextLine(isVertical: vertical, glyphs: [$0]) }
        }
        return lines
    }
    
    /// Gap along the reading axis, positive when `b` follows `a`
    private static func gap(_ a: CGRect, _ b: CGRect, vertical: Bool) -> CGFloat? {
        // furigana overlaps the selection box of its base text, but is about half its size
        guard isSimilarSize(vertical ? a.width : a.height, vertical ? b.width : b.height) else {
            return nil
        }
        if vertical {
            guard b.midY < a.midY else {
                return nil
            }
            let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            guard overlap > 0.5 * min(a.width, b.width) else {
                return nil
            }
            return a.minY - b.maxY
        }
        guard b.midX > a.midX else {
            return nil
        }
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard overlap > 0.5 * min(a.height, b.height) else {
            return nil
        }
        return b.minX - a.maxX
    }

    /// Cross-axis sizes of glyphs or lines that can share a line, ruby is about half the size of its base text
    static func isSimilarSize(_ a: CGFloat, _ b: CGFloat) -> Bool {
        min(a, b) >= 0.7 * max(a, b)
    }
    
    private static func medianGap(_ glyphs: [PDFGlyph], vertical: Bool, size: CGFloat) -> CGFloat? {
        var gaps: [CGFloat] = []
        for a in glyphs {
            var best: CGFloat?
            for b in glyphs where a.rect != b.rect {
                if let g = gap(a.rect, b.rect, vertical: vertical), g < 3 * size, best == nil || g < best! {
                    best = g
                }
            }
            if let best {
                gaps.append(best)
            }
        }
        guard gaps.count >= 2 else {
            return nil
        }
        gaps.sort()
        return gaps[gaps.count / 2]
    }
    
    private static func chains(_ glyphs: [PDFGlyph], vertical: Bool) -> [[PDFGlyph]] {
        var next: [Int?] = Array(repeating: nil, count: glyphs.count)
        var nextGap: [CGFloat] = Array(repeating: .infinity, count: glyphs.count)
        var previous: [Int?] = Array(repeating: nil, count: glyphs.count)
        
        for i in glyphs.indices {
            let a = glyphs[i].rect
            let size = max(a.width, a.height)
            var best: (index: Int, gap: CGFloat)?
            for j in glyphs.indices where j != i {
                guard let g = gap(a, glyphs[j].rect, vertical: vertical), g < size, g > -0.6 * size else {
                    continue
                }
                if best == nil || g < best!.gap {
                    best = (j, g)
                }
            }
            guard let best else {
                continue
            }
            // one predecessor per glyph, the closer one wins
            if let existing = previous[best.index] {
                guard best.gap < nextGap[existing] else {
                    continue
                }
                next[existing] = nil
            }
            next[i] = best.index
            nextGap[i] = best.gap
            previous[best.index] = i
        }
        
        var result: [[PDFGlyph]] = []
        for start in glyphs.indices where previous[start] == nil {
            var chain: [PDFGlyph] = []
            var current: Int? = start
            while let index = current {
                chain.append(glyphs[index])
                current = next[index]
            }
            result.append(chain)
        }
        return result
    }
}
