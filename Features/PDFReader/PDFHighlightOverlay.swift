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
    private let imageLayer = CALayer()
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

    /// Native selections are drawn by PDFKit below this view, the page shows its original while it has one
    var hidesImage = false {
        didSet { imageLayer.isHidden = hidesImage }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        // zooming scales this view, an animated frame would drift from the page
        imageLayer.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        imageLayer.contentsGravity = .resize
        imageLayer.isHidden = true
        layer.addSublayer(imageLayer)
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

    /// PDFKit turns this view with a rotated page, but the rendered image is already upright
    private func layoutImage() {
        let rotation = page?.rotation ?? 0
        let quarterTurn = rotation % 180 != 0
        imageLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: quarterTurn ? bounds.height : bounds.width,
            height: quarterTurn ? bounds.width : bounds.height
        )
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(rotation) * .pi / 180))
    }

    private func updateColor() {
        shapeLayer.fillColor = color.withAlphaComponent(0.3).resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutImage()
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

struct PDFTextBoxes {
    let main: [CGRect]
    let ruby: [CGRect]

    init(layer: PDFTextLayer) {
        main = layer.lines.filter { !$0.isRuby }.map(\.bounds)
        ruby = layer.lines.filter(\.isRuby).map(\.bounds)
    }
}

final class PDFHighlightOverlayProvider: NSObject, PDFPageOverlayViewProvider {
    weak var pdfView: PDFView?
    private var overlays: [Int: PDFHighlightOverlayView] = [:]
    private var highlight: (pageIndex: Int, rects: [CGRect])?
    private var boxes: [Int: PDFTextBoxes] = [:]
    // fitted upscaled pages, decoded so a page turn can show them right away
    private var images: [Int: CGImage] = [:]
    private var imageRecency: [Int] = []
    private var selectedPages: Set<Int> = []
    private static let imageLimit = 5

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
        overlay.hidesImage = selectedPages.contains(index)
        overlay.setImage(images[index], animated: false)
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        (overlayView as? PDFHighlightOverlayView)?.setImage(nil, animated: false)
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

    func hasImage(pageIndex: Int) -> Bool {
        images[pageIndex] != nil
    }

    func setImage(_ image: CGImage, pageIndex: Int) {
        images[pageIndex] = image
        imageRecency.removeAll { $0 == pageIndex }
        imageRecency.append(pageIndex)
        while imageRecency.count > Self.imageLimit {
            images[imageRecency.removeFirst()] = nil
        }
        overlays[pageIndex]?.setImage(image, animated: true)
    }

    /// Only forgets the decoded copy, a page on screen keeps showing it until it's replaced
    func removeImage(pageIndex: Int) {
        images[pageIndex] = nil
        imageRecency.removeAll { $0 == pageIndex }
    }

    func clearImages(keeping page: Int? = nil) {
        let kept = page.flatMap { images[$0] }
        images.removeAll()
        imageRecency.removeAll()
        for (index, overlay) in overlays where index != page {
            overlay.setImage(nil, animated: false)
        }
        if let page, let kept {
            images[page] = kept
            imageRecency = [page]
        } else if let page {
            overlays[page]?.setImage(nil, animated: false)
        }
    }

    func setSelectedPages(_ pages: Set<Int>) {
        selectedPages = pages
        for (index, overlay) in overlays {
            overlay.hidesImage = pages.contains(index)
        }
    }
}
