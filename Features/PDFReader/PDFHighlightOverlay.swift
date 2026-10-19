//
//  PDFHighlightOverlay.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit
#if os(iOS)
import UIKit
#endif

#if os(iOS)
final class PDFHighlightOverlayView: UIView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    private let shapeLayer = CAShapeLayer()
    private let mainBoxLayer = CAShapeLayer()
    private let rubyBoxLayer = CAShapeLayer()

    var pageRects: [CGRect] = [] {
        didSet { setNeedsLayout() }
    }

    // debug: text line bounds
    var boxes: PDFTextBoxes? {
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
        for (boxLayer, color) in [(mainBoxLayer, UIColor.systemBlue), (rubyBoxLayer, UIColor.systemOrange)] {
            boxLayer.fillColor = nil
            boxLayer.strokeColor = color.cgColor
            boxLayer.lineWidth = 1
            layer.addSublayer(boxLayer)
        }
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
        mainBoxLayer.frame = bounds
        rubyBoxLayer.frame = bounds
        updateColor()

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
        let path = UIBezierPath()
        for pageRect in pageRects {
            let rect = convert(pdfView.convert(pageRect, from: page), from: pdfView)
            path.append(UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius))
        }
        return path.cgPath
    }
}
#endif

struct PDFTextBoxes {
    let main: [CGRect]
    let ruby: [CGRect]

    init(layer: PDFTextLayer) {
        main = layer.lines.filter { !$0.isRuby }.map(\.bounds)
        ruby = layer.lines.filter(\.isRuby).map(\.bounds)
    }
}

#if os(iOS)
final class PDFHighlightOverlayProvider: NSObject, PDFPageOverlayViewProvider {
    weak var pdfView: PDFView?
    private var overlays: [Int: PDFHighlightOverlayView] = [:]
    private var highlight: (pageIndex: Int, rects: [CGRect])?
    private var boxes: [Int: PDFTextBoxes] = [:]

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
        overlay.boxes = boxes[index]
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

    func setBoxes(_ boxes: PDFTextBoxes, pageIndex: Int) {
        self.boxes[pageIndex] = boxes
        overlays[pageIndex]?.boxes = boxes
    }

    func clearBoxes() {
        boxes.removeAll()
        overlays.values.forEach { $0.boxes = nil }
    }

    func refreshLayout() {
        overlays.values.forEach { $0.setNeedsLayout() }
    }
}
#endif
