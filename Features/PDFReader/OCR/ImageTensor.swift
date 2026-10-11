//
//  ImageTensor.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Accelerate
import CoreGraphics

/// RGBA8 pixels, top-left origin, rows tightly packed
nonisolated struct PixelImage: Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            return nil
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// Bilinear resize with OpenCV's INTER_LINEAR sampling (no antialiasing), which is what PaddleOCR uses
    func resized(width newWidth: Int, height newHeight: Int) -> PixelImage {
        guard newWidth != width || newHeight != height else {
            return self
        }
        let xs = Self.samples(count: newWidth, source: width)
        let ys = Self.samples(count: newHeight, source: height)
        var output = [UInt8](repeating: 255, count: newWidth * newHeight * 4)
        pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                for (y, sampleY) in ys.enumerated() {
                    let row0 = sampleY.lower * width * 4
                    let row1 = sampleY.upper * width * 4
                    for (x, sampleX) in xs.enumerated() {
                        let a = sampleX.lower * 4
                        let b = sampleX.upper * 4
                        let out = (y * newWidth + x) * 4
                        for channel in 0..<3 {
                            let top = Float(source[row0 + a + channel]) * (1 - sampleX.weight) + Float(source[row0 + b + channel]) * sampleX.weight
                            let bottom = Float(source[row1 + a + channel]) * (1 - sampleX.weight) + Float(source[row1 + b + channel]) * sampleX.weight
                            destination[out + channel] = UInt8(top * (1 - sampleY.weight) + bottom * sampleY.weight + 0.5)
                        }
                    }
                }
            }
        }
        return PixelImage(width: newWidth, height: newHeight, pixels: output)
    }

    private struct Sample {
        let lower: Int
        let upper: Int
        let weight: Float
    }

    private static func samples(count: Int, source: Int) -> [Sample] {
        let scale = Double(source) / Double(count)
        return (0..<count).map { index in
            let position = min(max((Double(index) + 0.5) * scale - 0.5, 0), Double(source - 1))
            let lower = Int(position)
            return Sample(lower: lower, upper: min(lower + 1, source - 1), weight: Float(position - Double(lower)))
        }
    }

    /// Integer pixel rect, clamped to the image
    func cropped(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) -> PixelImage {
        let x0 = max(0, min(x, width))
        let y0 = max(0, min(y, height))
        let x1 = max(x0, min(x + cropWidth, width))
        let y1 = max(y0, min(y + cropHeight, height))
        let outWidth = x1 - x0
        var output = [UInt8](repeating: 0, count: outWidth * (y1 - y0) * 4)
        for row in y0..<y1 {
            let sourceStart = (row * width + x0) * 4
            let outputStart = (row - y0) * outWidth * 4
            output[outputStart..<(outputStart + outWidth * 4)] = pixels[sourceStart..<(sourceStart + outWidth * 4)]
        }
        return PixelImage(width: outWidth, height: y1 - y0, pixels: output)
    }

    /// Same as numpy's rot90: the top of the image becomes its left edge
    func rotatedCounterClockwise() -> PixelImage {
        var output = [UInt8](repeating: 0, count: pixels.count)
        // output is height wide and width tall; output(x, y) = source(width - 1 - y, x)
        pixels.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                let src = source.bindMemory(to: UInt32.self)
                let dst = destination.bindMemory(to: UInt32.self)
                for y in 0..<width {
                    let sourceX = width - 1 - y
                    for x in 0..<height {
                        dst[y * height + x] = src[x * width + sourceX]
                    }
                }
            }
        }
        return PixelImage(width: height, height: width, pixels: output)
    }

    /// Writes this image as 3 normalised float planes. `destination` points at the first plane;
    /// rows are `rowStride` floats apart, planes `rowStride * planeHeight`. Padding is left untouched.
    func writeTensor(to destination: UnsafeMutablePointer<Float>, rowStride: Int, planeHeight: Int, normalization: TensorNormalization) {
        let sourceChannels = normalization.channelOrder == .bgr ? [2, 1, 0] : [0, 1, 2]
        let planeSize = rowStride * planeHeight
        pixels.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else {
                return
            }
            for channel in 0..<3 {
                var multiplier = normalization.scale / normalization.std[channel]
                var offset = -normalization.mean[channel] / normalization.std[channel]
                let plane = destination + channel * planeSize
                for row in 0..<height {
                    let output = plane + row * rowStride
                    vDSP_vfltu8(base + row * width * 4 + sourceChannels[channel], 4, output, 1, vDSP_Length(width))
                    vDSP_vsmsa(output, 1, &multiplier, &offset, output, 1, vDSP_Length(width))
                }
            }
        }
    }
}
