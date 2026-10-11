//
//  InkLayout.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Places glyphs on the ink of a recognized line. DB boxes are much wider than the text (unclip padding,
/// furigana next to the column) and CTC peaks only roughly locate characters, so both are refined from the pixels.
/// Works on the recognition strip: reading direction left to right, x along the line, y across it.
nonisolated enum InkLayout {
    struct Result: Equatable {
        /// strip rows of the glyphs: the main text with a little margin, furigana and box padding excluded
        let cross: ClosedRange<Double>
        /// strip x range of each character
        let spans: [ClosedRange<Double>]
    }

    /// `centers` are the characters' CTC positions in strip pixels, `fullwidth` whether the line is fixed-pitch Japanese
    static func layout(_ strip: PixelImage, centers: [Double], fullwidth: Bool) -> Result? {
        guard !centers.isEmpty, strip.width > 1, strip.height > 1 else {
            return nil
        }
        let ink = inkMask(strip)
        guard let cross = mainBand(ink, width: strip.width, height: strip.height, pitch: pitch(centers)) else {
            return nil
        }
        let columns = columnProfile(ink, width: strip.width, rows: cross)
        guard let extent = inkExtent(columns, rows: cross) else {
            return nil
        }
        let thickness = Double(cross.count)
        // margin so strokes at the band's edge stay inside, and taps on them hit
        var half = 0.56 * thickness
        let spans: [ClosedRange<Double>]
        if fullwidth {
            let grid = gridSpans(centers: centers, columns: columns, extent: extent, thickness: thickness)
            spans = grid.spans
            // full-width glyphs sit in square cells; 、 and 。 are drawn at the cell's edge, outside the other glyphs' ink
            half = max(half, 0.5 * min(grid.cell, 1.2 * thickness))
        } else {
            spans = peakSpans(centers: centers, extent: extent)
        }
        let middle = Double(cross.lowerBound + cross.upperBound) / 2
        return Result(cross: max(0, middle - half)...min(Double(strip.height), middle + half), spans: spans)
    }

    // MARK: ink

    /// Text pixels, thresholded with Otsu's method so grey scans and faint print both work.
    /// Usually the dark ones, the light ones for light text on a dark background (title pages, captions).
    static func inkMask(_ image: PixelImage) -> [Bool] {
        let width = image.width
        let height = image.height
        let count = width * height
        var luminance = [UInt8](repeating: 255, count: count)
        var histogram = [Int](repeating: 0, count: 256)
        image.pixels.withUnsafeBufferPointer { pixels in
            for i in 0..<count {
                let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
                let value = (r * 299 + g * 587 + b * 114) / 1000
                luminance[i] = UInt8(value)
                histogram[value] += 1
            }
        }
        // never call light paper ink, even if the strip is almost blank
        let threshold = min(otsu(histogram, total: count), 160)

        // DB boxes are padded, so the strip's border is background. Mostly dark means light text, and taking
        // the dark background as ink would make the whole strip one band and stretch the character grid.
        var border = 0
        var dark = 0
        for y in 0..<height {
            let step = y == 0 || y == height - 1 ? 1 : max(1, width - 1)
            for x in stride(from: 0, to: width, by: step) {
                border += 1
                if Int(luminance[y * width + x]) < threshold {
                    dark += 1
                }
            }
        }
        let inverted = 2 * dark > border
        return luminance.map { (Int($0) < threshold) != inverted }
    }

    private static func otsu(_ histogram: [Int], total: Int) -> Int {
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var backgroundSum = 0.0
        var backgroundCount = 0
        var best = (threshold: 128, variance: -1.0)
        for t in 0..<256 {
            backgroundCount += histogram[t]
            guard backgroundCount > 0, backgroundCount < total else {
                continue
            }
            backgroundSum += Double(t * histogram[t])
            let foregroundCount = total - backgroundCount
            let meanBackground = backgroundSum / Double(backgroundCount)
            let meanForeground = (sum - backgroundSum) / Double(foregroundCount)
            let variance = Double(backgroundCount) * Double(foregroundCount) * (meanBackground - meanForeground) * (meanBackground - meanForeground)
            if variance > best.variance {
                best = (t + 1, variance)
            }
        }
        return best.threshold
    }

    // MARK: across the line

    /// The text band: the densest rows, grown outwards until the ink thins out or a gap separates furigana
    static func mainBand(_ ink: [Bool], width: Int, height: Int, pitch: Double?) -> Range<Int>? {
        var profile = [Int](repeating: 0, count: height)
        for y in 0..<height {
            var count = 0
            for x in 0..<width where ink[y * width + x] {
                count += 1
            }
            profile[y] = count
        }
        // DB boxes are centered on their text, so the band is found around the middle. A short furigana box
        // often reaches into the neighbouring column, whose ink is denser than its own.
        let middle = (height / 4)..<max(height / 4 + 1, height - height / 4)
        guard let peak = middle.max(by: { profile[$0] < profile[$1] }), profile[peak] >= 2 else {
            return nil
        }
        let maximum = Double(profile[peak])
        // stray specks in the padding stay below this, furigana and thin strokes at the band's edge don't
        let edge = max(2, Int(0.06 * maximum))
        let core = max(edge, Int(0.2 * maximum))

        var lower = peak
        var upper = peak
        // the core first, bridging the small gaps inside glyphs
        while lower > 0, profile[lower - 1] >= core { lower -= 1 }
        while upper < height - 1, profile[upper + 1] >= core { upper += 1 }
        // then the thinner edges, but no further than about one character: past that it's furigana or the next line
        let limit = pitch.map { Int(1.15 * $0) } ?? height
        while upper - lower + 1 < limit {
            let up = lower > 0 ? profile[lower - 1] : -1
            let down = upper < height - 1 ? profile[upper + 1] : -1
            guard max(up, down) >= edge else {
                break
            }
            if up >= down {
                lower -= 1
            } else {
                upper += 1
            }
        }
        return lower..<(upper + 1)
    }

    // MARK: along the line

    /// Ink per strip column, counted inside the band
    static func columnProfile(_ ink: [Bool], width: Int, rows: Range<Int>) -> [Int] {
        var columns = [Int](repeating: 0, count: width)
        for y in rows {
            for x in 0..<width where ink[y * width + x] {
                columns[x] += 1
            }
        }
        return columns
    }

    /// First and last ink column; specks need a neighbour to count
    static func inkExtent(_ columns: [Int], rows: Range<Int>) -> ClosedRange<Double>? {
        let width = columns.count
        let minimum = max(1, rows.count / 20)
        func solid(_ x: Int) -> Bool {
            columns[x] >= minimum && ((x > 0 && columns[x - 1] >= minimum) || (x < width - 1 && columns[x + 1] >= minimum))
        }
        guard let first = (0..<width).first(where: solid), let last = (0..<width).last(where: solid), last > first else {
            return nil
        }
        return Double(first)...Double(last + 1)
    }

    /// Median distance between neighbouring CTC peaks: the character pitch when few characters are dropped
    static func pitch(_ centers: [Double]) -> Double? {
        guard centers.count >= 3 else {
            return nil
        }
        let gaps = zip(centers.dropFirst(), centers).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        return gaps.isEmpty ? nil : gaps[gaps.count / 2]
    }

    /// Fixed-pitch text: lays a grid of character cells over the line and gives each character the cell under its CTC peak.
    /// Missed characters (often 、 and 。) leave their cell empty instead of shifting everything after them.
    static func gridSpans(centers: [Double], columns: [Int], extent: ClosedRange<Double>, thickness: Double) -> (spans: [ClosedRange<Double>], cell: Double) {
        let (cell, offset) = alignGrid(columns: columns, extent: extent, pitch: fittedPitch(centers, thickness: thickness))

        var spans: [ClosedRange<Double>] = []
        var previous: Int?
        for center in centers {
            var index = Int(((center - offset) / cell).rounded(.down))
            // in order, one character per cell
            if let previous {
                index = max(index, previous + 1)
            }
            spans.append((offset + Double(index) * cell)...(offset + Double(index + 1) * cell))
            previous = index
        }
        return (spans, cell)
    }

    /// Pitch from all CTC peaks: number the characters' cells (a gap of two pitches is a missed character), then fit a line
    static func fittedPitch(_ centers: [Double], thickness: Double) -> Double {
        // a full-width character is about as long as the line is thick
        let lowest = 0.8 * thickness
        let highest = 2 * thickness
        var pitch = min(max(Self.pitch(centers) ?? thickness, lowest), highest)
        var cells = [0]
        for _ in 0..<3 {
            cells = [0]
            for i in 1..<max(1, centers.count) {
                cells.append(cells[i - 1] + max(1, Int(((centers[i] - centers[i - 1]) / pitch).rounded())))
            }
            guard centers.count >= 3, let last = cells.last, last > 0 else {
                break
            }
            let meanCell = Double(cells.reduce(0, +)) / Double(cells.count)
            let meanCenter = centers.reduce(0, +) / Double(centers.count)
            var covariance = 0.0
            var variance = 0.0
            for (cell, center) in zip(cells, centers) {
                covariance += (Double(cell) - meanCell) * (center - meanCenter)
                variance += (Double(cell) - meanCell) * (Double(cell) - meanCell)
            }
            pitch = min(max(covariance / variance, lowest), highest)
        }
        return pitch
    }

    /// Cell size and grid offset whose boundaries fall on the blank space between characters.
    /// The pitch is searched close to the estimate only, since every multiple of it also lines up with gaps.
    static func alignGrid(columns: [Int], extent: ClosedRange<Double>, pitch estimate: Double) -> (cell: Double, offset: Double) {
        guard estimate >= 2 else {
            return (max(estimate, 1), extent.lowerBound)
        }
        // a little smoothing, so a boundary that just touches a stroke isn't scored as blank
        func ink(at position: Double) -> Double {
            let x = Int(position.rounded())
            var sum = 0
            for i in (x - 1)...(x + 1) where columns.indices.contains(i) {
                sum += columns[i]
            }
            return Double(sum)
        }
        var best = (score: Double.infinity, cell: estimate, offset: extent.lowerBound)
        for step in -20...20 {
            let cell = estimate * (1 + Double(step) * 0.0025)
            var offset = 0.0
            while offset < cell {
                var total = 0.0
                var count = 0
                // inner boundaries only, the outer ones are always on blank paper
                var boundary = offset + (((extent.lowerBound - offset) / cell).rounded(.down) + 1) * cell
                while boundary < extent.upperBound {
                    total += ink(at: boundary)
                    count += 1
                    boundary += cell
                }
                // prefer the estimate when the ink can't tell (short lines, touching glyphs)
                let score = (count > 0 ? total / Double(count) : 0) + abs(Double(step)) * 0.01
                if score < best.score {
                    best = (score, cell, offset)
                }
                offset += 0.5
            }
        }
        return (best.cell, best.offset)
    }

    /// Proportional text: boundaries halfway between CTC peaks, the outer ones on the ink
    static func peakSpans(centers: [Double], extent: ClosedRange<Double>) -> [ClosedRange<Double>] {
        let clamped = centers.map { min(max($0, extent.lowerBound), extent.upperBound) }
        var bounds = [extent.lowerBound]
        for i in 0..<(clamped.count - 1) {
            bounds.append(min(max((clamped[i] + clamped[i + 1]) / 2, bounds[bounds.count - 1]), extent.upperBound))
        }
        bounds.append(extent.upperBound)
        return clamped.indices.map { bounds[$0]...bounds[$0 + 1] }
    }
}
