//
//  PDFKitView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit
import SwiftUI

struct PDFKitViewState: Hashable {
    var displayMode: PDFDisplayMode
    var rightToLeft: Bool
}

extension PDFView {
    /// Converts a point in the view to coordinates with the origin at the top left, as SwiftUI
    /// uses. macOS views put the origin at the bottom left.
    func topLeftPoint(_ point: CGPoint) -> CGPoint {
        #if os(macOS)
        isFlipped ? point : CGPoint(x: point.x, y: bounds.height - point.y)
        #else
        point
        #endif
    }

    /// Converts a rect on `page` to view coordinates with the origin at the top left.
    func topLeftRect(for rect: CGRect, from page: PDFPage) -> CGRect {
        let converted = convert(rect, from: page)
        #if os(macOS)
        if !isFlipped {
            return CGRect(x: converted.minX, y: bounds.height - converted.maxY, width: converted.width, height: converted.height)
        }
        #endif
        return converted
    }
}

#if os(iOS)
/// PDFKit centers pages inside the safe area, so hiding the status bar with the reader controls moved the page.
/// The reader is full screen and the controls float on top, so the safe area is ignored.
final class ReaderPDFView: PDFView {
    override var safeAreaInsets: UIEdgeInsets {
        .zero
    }
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let initialPage: Int
    let displayMode: PDFDisplayMode
    let rightToLeft: Bool
    let onPageChanged: (Int) -> Void
    let onPageTap: (_ pageIndex: Int, _ pagePoint: CGPoint, _ viewPoint: CGPoint) -> Void
    let onTapOutside: (_ viewPoint: CGPoint) -> Void
    let onViewportChanged: () -> Void
    let onViewCreated: (PDFView, PDFHighlightOverlayProvider) -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = ReaderPDFView()
        let overlayProvider = PDFHighlightOverlayProvider()
        overlayProvider.pdfView = pdfView
        // before the document is assigned
        pdfView.pageOverlayViewProvider = overlayProvider
        pdfView.backgroundColor = .clear
        pdfView.autoScales = true
        
        switch displayMode {
        case .paged:
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .horizontal
            pdfView.usePageViewController(true, withViewOptions: nil)
            // edge to edge, paging already separates the pages
            pdfView.pageBreakMargins = .zero
            pdfView.pageShadowsEnabled = false
        case .continuous:
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
        }
        pdfView.displaysRTL = rightToLeft
        pdfView.document = document
        
        if let page = document.page(at: initialPage) {
            pdfView.go(to: page)
        }
        
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        pdfView.addGestureRecognizer(tap)
        
        // replaces PDFView's own double-tap zoom, which leaves the background around the page on screen
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        doubleTap.cancelsTouchesInView = false
        doubleTap.delaysTouchesEnded = false
        pdfView.addGestureRecognizer(doubleTap)
        context.coordinator.doubleTap = doubleTap
        
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged),
            name: .PDFViewScaleChanged,
            object: pdfView
        )
        
        let coordinator = context.coordinator
        coordinator.pdfView = pdfView
        coordinator.overlayProvider = overlayProvider
        coordinator.restoringPage = initialPage
        // PDFView can report its default page while laying out; ignore that until the restore settles
        DispatchQueue.main.async {
            if let page = pdfView.document?.page(at: initialPage) {
                pdfView.go(to: page)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            coordinator.restoringPage = nil
        }
        if displayMode == .continuous {
            // the scroll view is created lazily, so look it up after layout
            DispatchQueue.main.async { [weak coordinator] in
                coordinator?.observeScrolling()
            }
        }
        onViewCreated(pdfView, overlayProvider)
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.parent = self
    }
    
    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
    
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView
        weak var pdfView: PDFView?
        weak var doubleTap: UITapGestureRecognizer?
        var overlayProvider: PDFHighlightOverlayProvider?
        var restoringPage: Int?
        private var scrollObservation: NSKeyValueObservation?
        private var lastOffset: CGPoint?
        
        init(_ parent: PDFKitView) {
            self.parent = parent
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView, let document = pdfView.document else {
                return
            }
            if pdfView.currentSelection != nil {
                pdfView.clearSelection()
                return
            }
            let point = gesture.location(in: pdfView)
            guard let page = pdfView.page(for: point, nearest: false) else {
                parent.onTapOutside(point)
                return
            }
            let index = document.index(for: page)
            guard index != NSNotFound else {
                parent.onTapOutside(point)
                return
            }
            parent.onPageTap(index, pdfView.convert(point, to: page), point)
        }
        
        /// Toggles between fitting the page and filling the screen with it, keeping the zoomed view inside the page.
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView else {
                return
            }
            let point = gesture.location(in: pdfView)
            guard let scrollView = Self.zoomingScrollView(at: point, in: pdfView),
                  let zoomView = scrollView.delegate?.viewForZooming?(in: scrollView) else {
                return
            }
            let fitScale = pdfView.scaleFactorForSizeToFit
            if fitScale > 0, pdfView.scaleFactor > fitScale * 1.01 {
                let zoomScale = scrollView.zoomScale * fitScale / pdfView.scaleFactor
                scrollView.setZoomScale(max(zoomScale, scrollView.minimumZoomScale), animated: true)
                return
            }
            guard let page = pdfView.page(for: point, nearest: true) else {
                return
            }
            let pageRect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            let viewSize = pdfView.bounds.size
            guard pageRect.width > 0, pageRect.height > 0 else {
                return
            }
            var factor = max(viewSize.width / pageRect.width, viewSize.height / pageRect.height)
            if factor < 1.05 {
                // the page already fills the screen (continuous mode fits the width)
                factor = 2
            }
            let size = CGSize(width: viewSize.width / factor, height: viewSize.height / factor)
            let target = CGRect(
                x: Self.clamp(point.x - size.width / 2, size.width, within: pageRect.minX, pageRect.maxX),
                y: Self.clamp(point.y - size.height / 2, size.height, within: pageRect.minY, pageRect.maxY),
                width: size.width,
                height: size.height
            )
            scrollView.zoom(to: pdfView.convert(target, to: zoomView), animated: true)
        }
        
        /// Keeps a span of `length` starting at `origin` inside `lower...upper`, centering it when it doesn't fit.
        private static func clamp(_ origin: CGFloat, _ length: CGFloat, within lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            if length >= upper - lower {
                return (lower + upper - length) / 2
            }
            return min(max(origin, lower), upper - length)
        }
        
        /// In paged mode every page has its own zooming scroll view, so look up the one under the tap.
        private static func zoomingScrollView(at point: CGPoint, in pdfView: PDFView) -> UIScrollView? {
            var view = pdfView.hitTest(point, with: nil)
            while let current = view, current !== pdfView.superview {
                if let scrollView = current as? UIScrollView,
                   scrollView.maximumZoomScale > scrollView.minimumZoomScale,
                   scrollView.delegate?.viewForZooming?(in: scrollView) != nil {
                    return scrollView
                }
                view = current.superview
            }
            return nil
        }
        
        @objc func scaleChanged() {
            overlayProvider?.refreshLayout()
            parent.onViewportChanged()
        }
        
        func observeScrolling() {
            guard let scrollView = pdfView.flatMap(Self.findScrollView) else {
                return
            }
            scrollObservation = scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    let offset = scrollView.contentOffset
                    defer { self.lastOffset = offset }
                    // ignore PDFView's own layout adjustments
                    guard let last = self.lastOffset, hypot(offset.x - last.x, offset.y - last.y) > 2 else {
                        return
                    }
                    self.parent.onViewportChanged()
                }
            }
        }
        
        private static func findScrollView(in view: UIView) -> UIScrollView? {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            for subview in view.subviews {
                if let found = findScrollView(in: subview) {
                    return found
                }
            }
            return nil
        }

        /// Continuous pages, a zoomed page, or the page turn in paged mode, while still moving after a flick
        private static func deceleratingScrollViews(in view: UIView) -> [UIScrollView] {
            var result: [UIScrollView] = []
            if let scrollView = view as? UIScrollView, scrollView.isDecelerating {
                result.append(scrollView)
            }
            for subview in view.subviews {
                result += deceleratingScrollViews(in: subview)
            }
            return result
        }

        /// UIScrollView stops on touch down by itself, this covers the times PDFView's keeps going.
        private static func stopDecelerating(_ scrollView: UIScrollView) {
            // a paging scroll view would stop between pages
            guard scrollView.isDecelerating, !scrollView.isPagingEnabled else {
                return
            }
            // one bouncing back from past its edge would stay there
            let inset = scrollView.adjustedContentInset
            let offset = scrollView.contentOffset
            let minX = -inset.left
            let minY = -inset.top
            let maxX = max(minX, scrollView.contentSize.width + inset.right - scrollView.bounds.width)
            let maxY = max(minY, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
            guard offset.x >= minX - 1, offset.x <= maxX + 1, offset.y >= minY - 1, offset.y <= maxY + 1 else {
                return
            }
            scrollView.setContentOffset(offset, animated: false)
        }
        
        @objc func pageChanged() {
            guard let pdfView, let document = pdfView.document, let page = pdfView.currentPage else {
                return
            }
            let index = document.index(for: page)
            guard index != NSNotFound else {
                return
            }
            if let target = restoringPage {
                if index == target {
                    restoringPage = nil
                }
                return
            }
            parent.onPageChanged(index)
        }
        
        /// A tap on pages that are still moving only stops them, it doesn't look up a word or toggle the controls.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let pdfView else {
                return true
            }
            let moving = Self.deceleratingScrollViews(in: pdfView)
            if moving.isEmpty {
                return true
            }
            // after the scroll views have handled the touch
            DispatchQueue.main.async {
                moving.forEach(Self.stopDecelerating)
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            !(otherGestureRecognizer is UILongPressGestureRecognizer)
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // PDFView's double-tap zoom waits for ours, which always wins
            guard gestureRecognizer === doubleTap,
                  let other = otherGestureRecognizer as? UITapGestureRecognizer,
                  other !== doubleTap else {
                return false
            }
            return other.numberOfTapsRequired == 2
        }
    }
}
#endif
