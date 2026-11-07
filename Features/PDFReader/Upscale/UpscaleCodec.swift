//
//  UpscaleCodec.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// RGBX, 4 bytes per pixel, no row padding
nonisolated struct UpscaleBitmap: Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 255, count: width * height * 4)
    }

    init?(image: CGImage) {
        self.init(width: image.width, height: image.height)
        let width = width
        let height = height
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
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
    }

    /// The red channel only, for a bitmap that went through MonochromeGuard.makeNeutral
    func makeGrayImage() -> CGImage? {
        var gray = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            gray[index] = pixels[index * 4]
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

nonisolated enum UpscaleCodec {
    enum Format: String, CaseIterable, Sendable {
        case png
        case heic

        var type: UTType {
            self == .png ? .png : .heic
        }
    }

    static let heicQuality = 0.9

    /// Lossless grey keeps screentone exact in a quarter of the decoded memory, color pages need HEIC's size.
    static func encode(_ bitmap: UpscaleBitmap, monochrome: Bool) -> (data: Data, format: Format)? {
        if monochrome, let image = bitmap.makeGrayImage(), let data = encode(image, as: .png) {
            return (data, .png)
        }
        guard let image = bitmap.makeImage() else {
            return nil
        }
        if let data = encode(image, as: .heic) {
            return (data, .heic)
        }
        // the simulator has no HEIC encoder on some hosts
        return encode(image, as: .png).map { ($0, .png) }
    }

    static func encode(_ image: CGImage, as format: Format) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = format == .heic ? [kCGImageDestinationLossyCompressionQuality: heicQuality] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Decoded right away, so the layer showing it doesn't decode on the main thread.
    /// With `maxLongSide`, it's a proper downscale: a layer shrinking a 2x image would alias screentone.
    static func decode(_ url: URL, maxLongSide: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
        ]
        if let maxLongSide {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxLongSide
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
