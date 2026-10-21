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

/// The AppKit version of the per-page overlay that draws the lookup highlight
/// (and, in debug builds, the text line boxes) above a PDF page.
final class PDFHighlightOverlayView: NSView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
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
