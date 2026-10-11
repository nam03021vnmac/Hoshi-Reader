//
//  LayoutAnalyzer.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics

nonisolated enum LayoutAnalyzer {
    /// Merges collinear fragments, detects ruby, and returns lines in reading order with block indices assigned.
    static func analyze(_ input: [PDFTextLine]) -> [PDFTextLine] {
        var lines = input.filter { !$0.glyphs.isEmpty }
        guard !lines.isEmpty else {
            return []
        }

        let pageVertical = isPageVertical(lines)
        lines = lines.map { $0.glyphs.count == 1 ? PDFTextLine(isVertical: pageVertical, glyphs: $0.glyphs) : $0 }
        // pairwise merge is quadratic, skip it for garbage layers
        if lines.count <= 400 {
            lines = mergeCollinear(lines)
        }

        let rubyBase = detectRuby(lines)
        let mainIndices = lines.indices.filter { rubyBase[$0] == nil }
        let blocks = groupBlocks(lines: lines, indices: mainIndices, vertical: pageVertical)

        var result: [PDFTextLine] = []
        var rubyByBase: [Int: [Int]] = [:]
        for (ruby, base) in rubyBase {
            rubyByBase[base, default: []].append(ruby)
        }
        for (blockIndex, block) in blocks.enumerated() {
            for lineIndex in block {
                let main = lines[lineIndex]
                result.append(PDFTextLine(isVertical: main.isVertical, isRuby: false, blockIndex: blockIndex, glyphs: main.glyphs))
                let attached: [Int] = rubyByBase[lineIndex] ?? []
                for rubyIndex in attached.sorted(by: { order(lines[$0], lines[$1]) }) {
                    let ruby = lines[rubyIndex]
                    result.append(PDFTextLine(isVertical: ruby.isVertical, isRuby: true, blockIndex: blockIndex, glyphs: ruby.glyphs))
                }
            }
        }
        return result
    }

    private static func isPageVertical(_ lines: [PDFTextLine]) -> Bool {
        var vertical = 0
        var horizontal = 0
        var multi = lines.filter { $0.glyphs.count >= 2 }
        if multi.isEmpty {
            multi = lines
        }
        for line in multi {
            if line.isVertical {
                vertical += line.glyphs.count
            } else {
                horizontal += line.glyphs.count
            }
        }
        return vertical > horizontal
    }

    // MARK: merging

    private static func mergeCollinear(_ input: [PDFTextLine]) -> [PDFTextLine] {
        var lines = input
        var merged = true
        while merged {
            merged = false
            outer: for i in lines.indices {
                for j in lines.indices where j > i {
                    if let combined = merge(lines[i], lines[j]) {
                        lines[i] = combined
                        lines.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return lines
    }

    private static func merge(_ a: PDFTextLine, _ b: PDFTextLine) -> PDFTextLine? {
        guard a.isVertical == b.isVertical else {
            return nil
        }
        let vertical = a.isVertical
        // cross axis overlap
        let overlap = vertical
            ? overlapLength(a.bounds.minX, a.bounds.maxX, b.bounds.minX, b.bounds.maxX)
            : overlapLength(a.bounds.minY, a.bounds.maxY, b.bounds.minY, b.bounds.maxY)
        guard overlap > 0.5 * min(a.thickness, b.thickness) else {
            return nil
        }
        // reading axis gap, ordered so that `first` precedes `second`
        let aFirst = vertical ? a.bounds.midY > b.bounds.midY : a.bounds.midX < b.bounds.midX
        let (first, second) = aFirst ? (a, b) : (b, a)
        let gap = vertical ? first.bounds.minY - second.bounds.maxY : second.bounds.minX - first.bounds.maxX
        let size = max(first.glyphs.last?.rect.width ?? 0, first.glyphs.last?.rect.height ?? 0)
        guard gap < 1.5 * size, gap > -0.6 * size else {
            return nil
        }
        return PDFTextLine(isVertical: vertical, glyphs: first.glyphs + second.glyphs)
    }

    private static func overlapLength(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        max(0, min(a1, b1) - max(a0, b0))
    }

    // MARK: ruby

    /// Returns ruby line index -> index of the main line it annotates.
    private static func detectRuby(_ lines: [PDFTextLine]) -> [Int: Int] {
        let thicknesses = lines.filter { $0.glyphs.count >= 3 }.map(\.thickness).sorted()
        guard !thicknesses.isEmpty else {
            return [:]
        }
        let median = thicknesses[thicknesses.count / 2]
        guard median > 0 else {
            return [:]
        }

        let mainCandidates = lines.indices.filter { lines[$0].thickness >= 0.6 * median }
        var result: [Int: Int] = [:]
        for i in lines.indices where lines[i].thickness < 0.6 * median {
            let ruby = lines[i]
            var best: (index: Int, distance: CGFloat)?
            for j in mainCandidates {
                let main = lines[j]
                guard main.isVertical == ruby.isVertical else {
                    continue
                }
                let alongOverlap = ruby.isVertical
                    ? overlapLength(ruby.bounds.minY, ruby.bounds.maxY, main.bounds.minY, main.bounds.maxY)
                    : overlapLength(ruby.bounds.minX, ruby.bounds.maxX, main.bounds.minX, main.bounds.maxX)
                guard alongOverlap > 0 else {
                    continue
                }
                // ruby sits right of vertical lines and above horizontal lines
                let distance = ruby.isVertical ? ruby.bounds.minX - main.bounds.maxX : ruby.bounds.minY - main.bounds.maxY
                guard distance > -0.5 * median, distance < median else {
                    continue
                }
                if best == nil || distance < best!.distance {
                    best = (j, distance)
                }
            }
            if let best {
                result[i] = best.index
            }
        }
        return result
    }

    // MARK: ordering

    private static func order(_ a: PDFTextLine, _ b: PDFTextLine) -> Bool {
        a.isVertical ? a.bounds.midX > b.bounds.midX : a.bounds.midY > b.bounds.midY
    }

    /// Groups main lines into tiers (vertical pages) or columns (horizontal pages), each ordered for reading.
    private static func groupBlocks(lines: [PDFTextLine], indices: [Int], vertical: Bool) -> [[Int]] {
        var parent = Dictionary(uniqueKeysWithValues: indices.map { ($0, $0) })
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root {
                root = parent[root]!
            }
            return root
        }

        for (offset, i) in indices.enumerated() {
            for j in indices[(offset + 1)...] {
                let a = lines[i].bounds
                let b = lines[j].bounds
                let overlap = vertical
                    ? overlapLength(a.minY, a.maxY, b.minY, b.maxY)
                    : overlapLength(a.minX, a.maxX, b.minX, b.maxX)
                let shorter = vertical ? min(a.height, b.height) : min(a.width, b.width)
                if overlap > 0.5 * shorter {
                    parent[find(i)] = find(j)
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        for i in indices {
            groups[find(i), default: []].append(i)
        }

        func union(_ group: [Int]) -> CGRect {
            group.dropFirst().reduce(lines[group[0]].bounds) { $0.union(lines[$1].bounds) }
        }

        let sortedGroups = groups.values.sorted { a, b in
            let ua = union(a)
            let ub = union(b)
            return vertical ? ua.midY > ub.midY : ua.midX < ub.midX
        }
        return sortedGroups.map { group in
            group.sorted { i, j in
                let a = lines[i].bounds
                let b = lines[j].bounds
                return vertical ? a.midX > b.midX : a.midY > b.midY
            }
        }
    }
}
