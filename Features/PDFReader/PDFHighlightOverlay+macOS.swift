//
//  PDFHighlightOverlay+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import AppKit
import PDFKit

/// The AppKit version of the per-page overlay that draws the upscaled page image, the lookup
/// highlight and, in debug builds, the text line boxes above a PDF page.
final class PDFHighlightOverlayView: NSView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    private let imageLayer = CALayer()
    private let shapeLayer = CAShapeLayer()
    private let mainBoxLayer = CAShapeLayer()
    private let rubyBoxLayer = CAShapeLayer()

    var pageRects: [CGRect] = [] {
        didSet { needsLayout = true }
    }

    // debug: text line bounds
    var boxes: PDFTextBoxes? {
        didSet { needsLayout = true }
    }

    var color: NSColor = .tintColor {
        didSet { updateColor() }
    }

    /// Native selections are drawn by PDFKit below this view, the page shows its original while it has one
    var hidesImage = false {
        didSet { imageLayer.isHidden = hidesImage || imageLayer.contents == nil }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        // zooming scales this view, an animated frame would drift from the page
        imageLayer.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        imageLayer.contentsGravity = .resize
        imageLayer.isHidden = true
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(shapeLayer)
        for (boxLayer, color) in [(mainBoxLayer, NSColor.systemBlue), (rubyBoxLayer, NSColor.systemOrange)] {
            boxLayer.fillColor = nil
            boxLayer.strokeColor = color.cgColor
            boxLayer.lineWidth = 1
            layer?.addSublayer(boxLayer)
        }
        updateColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Fades when the page is already on screen, so the swap from the original isn't a jump
    func setImage(_ image: CGImage?, animated: Bool) {
        if animated, image != nil, imageLayer.contents == nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            imageLayer.add(fade, forKey: "contents")
        }
        imageLayer.contents = image
        imageLayer.isHidden = image == nil || hidesImage
    }

    /// PDFKit turns this view with a rotated page (its `frameRotation` is minus the page's
    /// rotation), but the rendered image is already upright. The view's y axis points up, so
    /// turning back is the opposite sign of the iOS version.
    private func layoutImage() {
        let rotation = page?.rotation ?? 0
        let quarterTurn = rotation % 180 != 0
        imageLayer.setAffineTransform(.identity)
        imageLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: quarterTurn ? bounds.height : bounds.width,
            height: quarterTurn ? bounds.width : bounds.height
        )
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180))
    }

    // clicks go through to the page
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shapeLayer.fillColor = color.withAlphaComponent(0.3).cgColor
        }
    }

    override func layout() {
        super.layout()
        // the shape layers draw without implicit animations, so a highlight doesn't slide between words
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layoutImage()
        shapeLayer.frame = bounds
        mainBoxLayer.frame = bounds
        rubyBoxLayer.frame = bounds

        guard let pdfView, let page else {
            shapeLayer.path = nil
            mainBoxLayer.path = nil
            rubyBoxLayer.path = nil
            return
        }
        shapeLayer.path = path(for: pageRects, pdfView: pdfView, page: page, cornerRadius: 2)
        mainBoxLayer.path = path(for: boxes?.main ?? [], pdfView: pdfView, page: page, cornerRadius: 0)
        rubyBoxLayer.path = path(for: boxes?.ruby ?? [], pdfView: pdfView, page: page, cornerRadius: 0)
    }

    private func path(for pageRects: [CGRect], pdfView: PDFView, page: PDFPage, cornerRadius: CGFloat) -> CGPath? {
        guard !pageRects.isEmpty else {
            return nil
        }
        let path = NSBezierPath()
        for pageRect in pageRects {
            let rect = convert(pdfView.convert(pageRect, from: page), from: pdfView)
            path.append(NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius))
        }
        return path.cgPath
    }
}
#endif
