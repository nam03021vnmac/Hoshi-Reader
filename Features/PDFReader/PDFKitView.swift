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
    let onPageTap: (Int, CGPoint) -> Void
    let onTapOutside: () -> Void
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
                parent.onTapOutside()
                return
            }
            let index = document.index(for: page)
            guard index != NSNotFound else {
                parent.onTapOutside()
                return
            }
            parent.onPageTap(index, pdfView.convert(point, to: page))
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
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            !(otherGestureRecognizer is UILongPressGestureRecognizer)
        }
    }
}
