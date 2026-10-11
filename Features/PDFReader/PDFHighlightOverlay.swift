//
//  PDFHighlightOverlay.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit
import UIKit

final class PDFHighlightOverlayView: UIView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    private let shapeLayer = CAShapeLayer()

    var pageRects: [CGRect] = [] {
        didSet { setNeedsLayout() }
    }

    var color: UIColor = .tintColor {
        didSet { updateColor() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(shapeLayer)
        updateColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateColor() {
        shapeLayer.fillColor = color.withAlphaComponent(0.3).resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
        updateColor()

        guard let pdfView, let page, !pageRects.isEmpty else {
            shapeLayer.path = nil
            return
        }
        let path = UIBezierPath()
        for pageRect in pageRects {
            let rect = convert(pdfView.convert(pageRect, from: page), from: pdfView)
            path.append(UIBezierPath(roundedRect: rect, cornerRadius: 2))
        }
        shapeLayer.path = path.cgPath
    }
}

final class PDFHighlightOverlayProvider: NSObject, PDFPageOverlayViewProvider {
    weak var pdfView: PDFView?
    private var overlays: [Int: PDFHighlightOverlayView] = [:]
    private var highlight: (pageIndex: Int, rects: [CGRect])?

    var color: UIColor = .tintColor {
        didSet { overlays.values.forEach { $0.color = color } }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let overlay = PDFHighlightOverlayView()
        overlay.pdfView = view
        overlay.page = page
        overlay.color = color
        guard let index = view.document?.index(for: page), index != NSNotFound else {
            return overlay
        }
        overlays[index] = overlay
        if let highlight, highlight.pageIndex == index {
            overlay.pageRects = highlight.rects
        }
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let index = pdfView.document?.index(for: page), index != NSNotFound else {
            return
        }
        if overlays[index] === overlayView {
            overlays[index] = nil
        }
    }

    func setHighlight(pageIndex: Int, rects: [CGRect]) {
        clear()
        highlight = (pageIndex, rects)
        overlays[pageIndex]?.pageRects = rects
    }

    func clear() {
        if let highlight {
            overlays[highlight.pageIndex]?.pageRects = []
        }
        highlight = nil
    }

    func refreshLayout() {
        overlays.values.forEach { $0.setNeedsLayout() }
    }
}
