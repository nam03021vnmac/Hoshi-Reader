//
//  PageRenderer.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit
import UIKit

nonisolated struct RenderedPage {
    let image: CGImage
    // image pixel (top-left origin) -> PDF page space
    let pixelToPage: CGAffineTransform
}

nonisolated enum PageRenderer {
    static func render(_ page: PDFPage, longSide: CGFloat) -> RenderedPage? {
        let box: PDFDisplayBox = .cropBox
        let transform = page.transform(for: box)
        let rotated = page.bounds(for: box).applying(transform)
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
        
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: box, to: context)
        
        guard let image = context.makeImage() else {
            return nil
        }
        
        // pixel (top-left) -> rotated space -> page space
        let pixelToRotated = CGAffineTransform(a: 1 / scale, b: 0, c: 0, d: -1 / scale, tx: 0, ty: CGFloat(height) / scale)
        let pixelToPage = pixelToRotated.concatenating(transform.inverted())
        return RenderedPage(image: image, pixelToPage: pixelToPage)
    }
}
