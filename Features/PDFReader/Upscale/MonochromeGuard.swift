//
//  MonochromeGuard.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Port of monochrome_guard.h from HaoweiLi97/mihon_img_upscale (Apache-2.0).
//

import Foundation

/// The model invents color fringes, also in the grey parts of color pages. Pages detected as neutral get
/// neutral output, the others keep the model's brightness with their color taken from the source.
nonisolated enum MonochromeGuard {
    private static let sampleAxis = 64
    private static let blockSize = 16

    /// Tolerates sparse, weak compression noise. A small colored panel or strong accent still counts as color.
    static func isNeutral(_ bitmap: UpscaleBitmap) -> Bool {
        let width = bitmap.width
        let height = bitmap.height
        guard width > 0, height > 0 else {
            return false
        }
        return bitmap.pixels.withUnsafeBufferPointer { pixels in
            let stepX = 1 + (width - 1) / sampleAxis
            let stepY = 1 + (height - 1) / sampleAxis
            var samples = 0
            var weakSamples = 0
            for y in stride(from: stepY / 2, to: height, by: stepY) {
                for x in stride(from: stepX / 2, to: width, by: stepX) {
                    let chroma = chroma(pixels, (y * width + x) * 4)
                    samples += 1
                    if chroma > 8 {
                        return false
                    }
                    if chroma > 2 {
                        weakSamples += 1
                    }
                }
            }
            if weakSamples > max(4, samples / 100) {
                return false
            }

            let count = width * height
            let noiseLimit = max(1, count / 2000)
            var noise = 0
            for block in stride(from: 0, to: count, by: blockSize) {
                var blockNoise = 0
                for index in block..<min(block + blockSize, count) {
                    let chroma = chroma(pixels, index * 4)
                    guard chroma > 2 else {
                        continue
                    }
                    blockNoise += 1
                    noise += 1
                    if chroma > 8 || blockNoise > 2 || noise > noiseLimit {
                        return false
                    }
                }
            }
            return true
        }
    }

    static func makeNeutral(_ bitmap: inout UpscaleBitmap) {
        let count = bitmap.width * bitmap.height
        bitmap.pixels.withUnsafeMutableBufferPointer { (pixels: inout UnsafeMutableBufferPointer<UInt8>) in
            for index in 0..<count {
                let offset = index * 4
                let red = Int(pixels[offset]) * 77
                let green = Int(pixels[offset + 1]) * 150
                let blue = Int(pixels[offset + 2]) * 29
                let weighted: Int = red + green + blue + 128
                let luma = UInt8(weighted >> 8)
                pixels[offset] = luma
                pixels[offset + 1] = luma
                pixels[offset + 2] = luma
            }
        }
    }

    /// `output` is a 2x upscale of `source`
    static func restoreColor(_ output: inout UpscaleBitmap, source: UpscaleBitmap) {
        let sourceWidth = source.width
        let sourceHeight = source.height
        guard output.width == sourceWidth * 2, output.height == sourceHeight * 2 else {
            return
        }
        // each channel's difference from luma, at the source's resolution
        var color = [Int16](repeating: 0, count: sourceWidth * sourceHeight * 3)
        source.pixels.withUnsafeBufferPointer { (pixels: UnsafeBufferPointer<UInt8>) in
            for index in 0..<(sourceWidth * sourceHeight) {
                let offset = index * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                let weighted: Int = red * 77 + green * 150 + blue * 29 + 128
                let luma = weighted >> 8
                color[index * 3] = Int16(red - luma)
                color[index * 3 + 1] = Int16(green - luma)
                color[index * 3 + 2] = Int16(blue - luma)
            }
        }
        
        let width = output.width
        let height = output.height
        output.pixels.withUnsafeMutableBufferPointer { (pixels: inout UnsafeMutableBufferPointer<UInt8>) in
            for y in 0..<height {
                let lowY = max((y - 1) / 2 - (y == 0 ? 1 : 0), 0)
                let highY = min(lowY + 1, sourceHeight - 1)
                let weightY = y % 2 == 0 ? 3 : 1
                for x in 0..<width {
                    let lowX = max((x - 1) / 2 - (x == 0 ? 1 : 0), 0)
                    let highX = min(lowX + 1, sourceWidth - 1)
                    let weightX = x % 2 == 0 ? 3 : 1
                    let offset = (y * width + x) * 4
                    let red = Int(pixels[offset]) * 77
                    let green = Int(pixels[offset + 1]) * 150
                    let blue = Int(pixels[offset + 2]) * 29
                    let weighted: Int = red + green + blue + 128
                    let luma = weighted >> 8
                    let topLeft = (lowY * sourceWidth + lowX) * 3
                    let topRight = (lowY * sourceWidth + highX) * 3
                    let bottomLeft = (highY * sourceWidth + lowX) * 3
                    let bottomRight = (highY * sourceWidth + highX) * 3
                    for channel in 0..<3 {
                        let top = Int(color[topLeft + channel]) * (4 - weightX) + Int(color[topRight + channel]) * weightX
                        let bottom = Int(color[bottomLeft + channel]) * (4 - weightX) + Int(color[bottomRight + channel]) * weightX
                        let mixed: Int = top * (4 - weightY) + bottom * weightY
                        // rounded to nearest, also below zero
                        let difference = (mixed + 8) >> 4
                        pixels[offset + channel] = UInt8(min(max(luma + difference, 0), 255))
                    }
                }
            }
        }
    }
    
    @inline(__always)
    private static func chroma(_ pixels: UnsafeBufferPointer<UInt8>, _ offset: Int) -> Int {
        let red = pixels[offset]
        let green = pixels[offset + 1]
        let blue = pixels[offset + 2]
        return Int(max(red, green, blue)) - Int(min(red, green, blue))
    }
}
