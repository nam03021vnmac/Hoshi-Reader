//
//  FullscreenImageView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import AppKit
import SwiftUI

/// The image fits the view; pinch or double-click to zoom, then scroll or drag to pan.
struct ZoomableImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> ImageScrollView {
        ImageScrollView(url: url)
    }

    func updateNSView(_ nsView: ImageScrollView, context: Context) {}
}

final class ImageScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var dragOrigin: (point: CGPoint, bounds: CGPoint)?

    init(url: URL) {
        super.init(frame: .zero)
        imageView.image = NSImage(contentsOf: url)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        contentView = CenteringClipView()
        contentView.drawsBackground = false
        documentView = imageView
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 5
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // the image keeps its fitted size and magnification scales it
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else {
            return
        }
        let available = contentSize
        let scale = min(available.width / size.width, available.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        if imageView.frame.size != fitted {
            imageView.frame = CGRect(origin: .zero, size: fitted)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            dragOrigin = (event.locationInWindow, contentView.bounds.origin)
            return
        }
        dragOrigin = nil
        if magnification > minMagnification {
            animator().magnification = minMagnification
        } else {
            // about 3x zoom
            let point = imageView.convert(event.locationInWindow, from: nil)
            animator().setMagnification(3, centeredAt: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, magnification > minMagnification else {
            return
        }
        // the content follows the pointer
        let dx = (event.locationInWindow.x - dragOrigin.point.x) / magnification
        let dy = (event.locationInWindow.y - dragOrigin.point.y) / magnification
        let flip: CGFloat = contentView.isFlipped ? 1 : -1
        var bounds = contentView.bounds
        bounds.origin = CGPoint(x: dragOrigin.bounds.x - dx, y: dragOrigin.bounds.y + flip * dy)
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }
}

/// Keeps the document centered while it's smaller than the view.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else {
            return rect
        }
        let frame = documentView.frame
        if rect.width > frame.width {
            rect.origin.x = frame.minX - (rect.width - frame.width) / 2
        }
        if rect.height > frame.height {
            rect.origin.y = frame.minY - (rect.height - frame.height) / 2
        }
        return rect
    }
}
#endif
