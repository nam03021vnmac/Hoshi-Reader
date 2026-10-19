//
//  PDFKitView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import AppKit
import PDFKit
import SwiftUI

/// The PDF view behind the reader on macOS. A plain click looks up a word, a double click
/// toggles zoom, and in paged mode the keyboard, the scroll wheel and trackpad swipes turn
/// pages. Clicks that only clear a selection, end a drag, or follow a link don't look up.
final class ReaderPDFView: PDFView {
    var onClick: ((CGPoint) -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?
    var pagedNavigation: ((NavigationDirection) -> Void)?
    var rightToLeft = false
    private let pageTurner = ScrollPageTurner()
    private var pendingClick: (point: CGPoint, hadSelection: Bool)?
    private var eventMonitor: Any?

    private var hasSelection: Bool {
        !(currentSelection?.string ?? "").isEmpty
    }

    /// Whether the page is zoomed past fitting the view, so scrolling pans instead of turning pages.
    var isZoomedIn: Bool {
        let fitScale = scaleFactorForSizeToFit
        return fitScale > 0 && scaleFactor > fitScale * 1.01
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        guard window != nil else {
            return
        }
        // the scroll view inside PDFView handles keys and scrolling before this view sees
        // them, so paged mode picks them out of the window's events first
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window else {
                return event
            }
            switch event.type {
            case .keyDown:
                return self.handlePagedKey(event) ? nil : event
            case .scrollWheel:
                return self.handlePagedScroll(event) ? nil : event
            default:
                return event
            }
        }
        // take the keyboard right away so the arrow keys work without clicking first
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            // instead of selecting the word, which the first click already looked up
            pendingClick = nil
            onDoubleClick?(point)
            return
        }
        pendingClick = event.clickCount == 1 && !isLink(at: point) ? (point, hasSelection) : nil
        super.mouseDown(with: event)
        // PDFView tracks the drag itself and can swallow the mouse up
        if let current = NSApp.currentEvent, current.type == .leftMouseUp {
            finishClick(current)
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        finishClick(event)
    }

    private func finishClick(_ event: NSEvent) {
        guard let click = pendingClick else {
            return
        }
        pendingClick = nil
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - click.point.x, point.y - click.point.y) < 4,
              !click.hadSelection,
              !hasSelection,
              !event.modifierFlags.contains(.command) else {
            return
        }
        onClick?(click.point)
    }

    private func isLink(at point: CGPoint) -> Bool {
        guard let page = page(for: point, nearest: false),
              let annotation = page.annotation(at: convert(point, to: page)) else {
            return false
        }
        return annotation.url != nil || annotation.destination != nil || annotation.action != nil
    }

    /// Whether keys typed now are meant for the page: nothing else in the window, such as
    /// a popup or a text field, has the keyboard.
    private var hasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else {
            return false
        }
        if responder === window {
            return true
        }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }

    private func handlePagedKey(_ event: NSEvent) -> Bool {
        guard let pagedNavigation,
              hasKeyboardFocus,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        let direction: NavigationDirection
        switch event.specialKey {
        case .leftArrow:
            direction = rightToLeft ? .forward : .backward
        case .rightArrow:
            direction = rightToLeft ? .backward : .forward
        case .downArrow, .pageDown:
            direction = .forward
        case .upArrow, .pageUp:
            direction = .backward
        default:
            guard event.charactersIgnoringModifiers == " " else {
                return false
            }
            direction = event.modifierFlags.contains(.shift) ? .backward : .forward
        }
        pagedNavigation(direction)
        return true
    }

    private func handlePagedScroll(_ event: NSEvent) -> Bool {
        // a zoomed page pans, and pinch or ⌘-scroll zooms as usual
        guard let pagedNavigation,
              !isZoomedIn,
              !event.modifierFlags.contains(.command),
              let hitView = window?.contentView?.hitTest(event.locationInWindow),
              hitView.isDescendant(of: self) else {
            return false
        }
        guard let delta = pageTurner.pageTurnDelta(for: event) else {
            return true
        }
        if abs(delta.width) > abs(delta.height) {
            // a leftward swipe shows the page to the right
            pagedNavigation((delta.width < 0) != rightToLeft ? .forward : .backward)
        } else if delta.height != 0 {
            pagedNavigation(delta.height < 0 ? .forward : .backward)
        }
        return true
    }

    /// PDFView's own menu switches display modes behind the reader's settings, so offer
    /// just copying and zooming.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if hasSelection {
            menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: String(localized: "Zoom In"), action: #selector(zoomIn(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Zoom Out"), action: #selector(zoomOut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Zoom to Fit"), action: #selector(zoomToFit(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc func zoomToFit(_ sender: Any?) {
        autoScales = true
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let initialPage: Int
    let displayMode: PDFDisplayMode
    let rightToLeft: Bool
    let onPageChanged: (Int) -> Void
    let onPageTap: (_ pageIndex: Int, _ pagePoint: CGPoint, _ viewPoint: CGPoint) -> Void
    let onTapOutside: (_ viewPoint: CGPoint) -> Void
    let onViewportChanged: () -> Void
    let onViewCreated: (PDFView, PDFHighlightOverlayProvider) -> Void

    func makeNSView(context: Context) -> PDFView {
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
            // edge to edge, paging already separates the pages
            pdfView.pageBreakMargins = NSEdgeInsetsZero
            pdfView.pageShadowsEnabled = false
            pdfView.pagedNavigation = { [weak pdfView] direction in
                guard let pdfView else { return }
                switch direction {
                case .forward:
                    pdfView.goToNextPage(nil)
                case .backward:
                    pdfView.goToPreviousPage(nil)
                }
            }
        case .continuous:
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
        }
        pdfView.displaysRTL = rightToLeft
        pdfView.rightToLeft = rightToLeft
        pdfView.document = document

        if let page = document.page(at: initialPage) {
            pdfView.go(to: page)
        }

        let coordinator = context.coordinator
        pdfView.onClick = { [weak coordinator] point in
            coordinator?.handleClick(at: point)
        }
        pdfView.onDoubleClick = { [weak coordinator] point in
            coordinator?.toggleZoom(at: point)
        }

        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.scaleChanged),
            name: .PDFViewScaleChanged,
            object: pdfView
        )

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
        // the scroll view is set up with the document, so look it up after layout
        DispatchQueue.main.async { [weak coordinator] in
            coordinator?.observeScrolling()
        }
        onViewCreated(pdfView, overlayProvider)
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: PDFKitView
        weak var pdfView: PDFView?
        var overlayProvider: PDFHighlightOverlayProvider?
        var restoringPage: Int?
        private var lastOrigin: CGPoint?

        init(_ parent: PDFKitView) {
            self.parent = parent
        }

        /// `point` is in PDFView coordinates; the callbacks get it with the origin at the top
        /// left, the way SwiftUI lays out the popups and controls.
        func handleClick(at point: CGPoint) {
            guard let pdfView, let document = pdfView.document else {
                return
            }
            let viewPoint = pdfView.topLeftPoint(point)
            guard let page = pdfView.page(for: point, nearest: false) else {
                parent.onTapOutside(viewPoint)
                return
            }
            let index = document.index(for: page)
            guard index != NSNotFound else {
                parent.onTapOutside(viewPoint)
                return
            }
            parent.onPageTap(index, pdfView.convert(point, to: page), viewPoint)
        }

        /// Toggles between fitting the page and filling the view with it, keeping the clicked
        /// spot under the pointer.
        func toggleZoom(at point: CGPoint) {
            guard let pdfView else {
                return
            }
            let fitScale = pdfView.scaleFactorForSizeToFit
            if fitScale > 0, pdfView.scaleFactor > fitScale * 1.01 {
                pdfView.autoScales = true
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
                // the page already fills the view (continuous mode fits the width)
                factor = 2
            }
            let pagePoint = pdfView.convert(point, to: page)
            pdfView.scaleFactor *= factor
            pdfView.layoutDocumentView()
            guard let clipView = pdfView.documentView?.enclosingScrollView?.contentView else {
                return
            }
            let target = clipView.convert(pdfView.convert(pagePoint, from: page), from: pdfView)
            let anchor = clipView.convert(point, from: pdfView)
            var bounds = clipView.bounds
            bounds.origin.x += target.x - anchor.x
            bounds.origin.y += target.y - anchor.y
            clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
            clipView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        @objc func scaleChanged() {
            overlayProvider?.refreshLayout()
            parent.onViewportChanged()
        }

        func observeScrolling() {
            guard let clipView = pdfView?.documentView?.enclosingScrollView?.contentView else {
                return
            }
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        @objc private func boundsChanged(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else {
                return
            }
            let origin = clipView.bounds.origin
            defer { lastOrigin = origin }
            // ignore PDFView's own layout adjustments
            guard let last = lastOrigin, hypot(origin.x - last.x, origin.y - last.y) > 2 else {
                return
            }
            parent.onViewportChanged()
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
    }
}
#endif
