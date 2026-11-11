//
//  PageRenderer.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import PDFKit

nonisolated struct RenderedPage: Sendable {
    let image: CGImage
    // image pixel (top-left origin) -> PDF page space
    let pixelToPage: CGAffineTransform
}

nonisolated enum PageRenderer {
    /// Japanese body text in a bunko scan is ~25–30 px per character at this size
    static let ocrLongSide: CGFloat = 2048

    /// `region` is in page space and limits the image to that part of the page
    static func render(_ page: PDFPage, longSide: CGFloat, region: CGRect? = nil) -> RenderedPage? {
        let box: PDFDisplayBox = .cropBox
        let transform = page.transform(for: box)
        let rotated = (region ?? page.bounds(for: box)).applying(transform).standardized
        guard rotated.width > 0, rotated.height > 0 else {
            return nil
        }
        
        let scale = longSide / max(rotated.width, rotated.height)
        let width = max(1, Int((rotated.width * scale).rounded()))
        let height = max(1, Int((rotated.height * scale).rounded()))
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rotated.minX, y: -rotated.minY)
        page.draw(with: box, to: context)

        guard let image = context.makeImage() else {
            return nil
        }

        // pixel (top-left) -> rotated space -> page space
        let pixelToRotated = CGAffineTransform(a: 1 / scale, b: 0, c: 0, d: -1 / scale, tx: rotated.minX, ty: rotated.minY + CGFloat(height) / scale)
        let pixelToPage = pixelToRotated.concatenating(transform.inverted())
        return RenderedPage(image: image, pixelToPage: pixelToPage)
    }
}
