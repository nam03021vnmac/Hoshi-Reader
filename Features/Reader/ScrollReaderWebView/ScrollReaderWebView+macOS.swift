//
//  ScrollReaderWebView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import AppKit
import SwiftUI
import WebKit

// The macOS WKWebView scrolls inside its own process and has no scroll view delegate, so
// scroll progress comes from `readerScroll` messages that `scrollScript` posts, and
// scrolling past either end of a chapter is measured from the wheel events themselves.
extension ScrollReaderWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let input = ScrollReaderInput(coordinator: coordinator)
        let config = makeConfiguration(coordinator: coordinator)
        config.userContentController.add(ReaderScriptMessageRelay { [weak coordinator] message in
            guard let body = message.body as? [String: Any],
                  let x = body["x"] as? CGFloat,
                  let y = body["y"] as? CGFloat else {
                return
            }
            coordinator?.handleTap(at: CGPoint(x: x, y: y))
        }, name: "readerClick")
        config.userContentController.add(ReaderScriptMessageRelay { [weak input] message in
            input?.handleScrollMessage(message.body)
        }, name: "readerScroll")
        config.userContentController.addUserScript(WKUserScript(
            source: HoshiWKWebView.clickScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        config.userContentController.addUserScript(WKUserScript(
            source: ScrollReaderInput.scrollScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let webView = HoshiWKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.inputHandler = input
        prepare(webView, coordinator: coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        updateWebView(webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readerClick")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readerScroll")
        dismantleWebView(webView, coordinator: coordinator)
    }
}

extension ScrollReaderWebView.Coordinator {
    /// The macOS web view has no scroll view, and JS reports rects relative to the viewport.
    func scrollOrigin(of webView: WKWebView?) -> CGPoint {
        .zero
    }

    /// Scroll callbacks are turned off while a chapter loads or restores its position.
    func setScrollTracking(_ enabled: Bool) {
        guard let webView = webView as? HoshiWKWebView,
              let input = webView.inputHandler as? ScrollReaderInput else {
            return
        }
        input.isTracking = enabled
        if enabled {
            input.refreshEdges(of: webView)
        }
    }

    /// macOS has no double-tap-to-zoom gesture to remove.
    func removeDoubleTapZoom(from webView: WKWebView) {}
}

/// Tracks scrolling for the Coordinator, and changes chapters when the reader keeps
/// scrolling or paging past either end of one.
@MainActor
private final class ScrollReaderInput: ReaderInputHandling {
    /// Reports whether the page is at its start or end after each scroll, at most once per
    /// frame. In vertical writing, a vertical mouse wheel scrolls the page sideways.
    static let scrollScript = """
    (function() {
        function isVertical() {
            return window.getComputedStyle(document.documentElement).writingMode === 'vertical-rl';
        }
        window.hoshiScrollEdges = function() {
            const el = document.scrollingElement || document.documentElement;
            const vertical = isVertical();
            // vertical-rl pages start at scrollLeft 0 and scroll to negative values
            const position = vertical ? Math.abs(el.scrollLeft) : el.scrollTop;
            const max = vertical ? el.scrollWidth - el.clientWidth : el.scrollHeight - el.clientHeight;
            return { atStart: position <= 1, atEnd: position >= max - 1 };
        };
        let scheduled = false;
        window.addEventListener('scroll', () => {
            if (scheduled) {
                return;
            }
            scheduled = true;
            requestAnimationFrame(() => {
                scheduled = false;
                webkit.messageHandlers.readerScroll.postMessage(window.hoshiScrollEdges());
            });
        }, { passive: true });
        window.addEventListener('wheel', event => {
            if (!isVertical() || Math.abs(event.deltaY) <= Math.abs(event.deltaX)) {
                return;
            }
            event.preventDefault();
            const scale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? window.innerWidth : 1;
            window.scrollBy(-event.deltaY * scale, 0);
        }, { passive: false });
    })();
    """

    private weak var coordinator: ScrollReaderWebView.Coordinator?
    var isTracking = false
    private var atStart = true
    private var atEnd = false
    /// How far the current gesture has pushed past the start (negative) or end (positive).
    private var overscroll: CGFloat = 0
    private var lastWheelEvent: TimeInterval = 0
    private var scrollEnded: DispatchWorkItem?

    init(coordinator: ScrollReaderWebView.Coordinator) {
        self.coordinator = coordinator
    }

    func handleScrollMessage(_ body: Any) {
        if let edges = body as? [String: Any] {
            updateEdges(edges)
        }
        guard isTracking, let coordinator else { return }
        coordinator.handleScroll()

        scrollEnded?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isTracking else { return }
            self.coordinator?.handleScrollEnded()
        }
        scrollEnded = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func refreshEdges(of webView: WKWebView) {
        webView.evaluateJavaScript("window.hoshiScrollEdges && window.hoshiScrollEdges()") { [weak self] result, _ in
            if let edges = result as? [String: Any] {
                self?.updateEdges(edges)
            }
        }
    }

    private func updateEdges(_ edges: [String: Any]) {
        atStart = edges["atStart"] as? Bool ?? atStart
        atEnd = edges["atEnd"] as? Bool ?? atEnd
    }

    func keyDown(with event: NSEvent) -> Bool {
        guard let coordinator, isTracking,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        let vertical = coordinator.parent.userConfig.verticalWriting
        let isPageKey: Bool
        let direction: NavigationDirection
        switch event.specialKey {
        case .pageDown:
            (direction, isPageKey) = (.forward, true)
        case .pageUp:
            (direction, isPageKey) = (.backward, true)
        case .downArrow where !vertical, .leftArrow where vertical:
            (direction, isPageKey) = (.forward, false)
        case .upArrow where !vertical, .rightArrow where vertical:
            (direction, isPageKey) = (.backward, false)
        default:
            guard event.charactersIgnoringModifiers == " " else {
                return false
            }
            (direction, isPageKey) = (event.modifierFlags.contains(.shift) ? .backward : .forward, true)
        }

        if direction == .forward ? atEnd : atStart {
            changeChapter(direction)
            return true
        }
        // WebKit pages along the vertical axis, which a vertical-rl page can't scroll
        if vertical && isPageKey, let webView = coordinator.webView {
            let sign = direction == .forward ? "-" : ""
            webView.evaluateJavaScript("window.scrollBy({ left: \(sign)window.innerWidth * 0.9, behavior: 'smooth' })")
            return true
        }
        return false
    }

    func scrollWheel(with event: NSEvent) -> Bool {
        guard let coordinator, isTracking else {
            return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        // a new trackpad gesture, or a mouse wheel that paused, starts measuring again
        if event.phase.contains(.began) || (event.phase.isEmpty && now - lastWheelEvent > 0.5) {
            overscroll = 0
        }
        lastWheelEvent = now
        // flinging into an edge shouldn't change chapters on its own
        guard event.momentumPhase.isEmpty else {
            return false
        }

        let vertical = coordinator.parent.userConfig.verticalWriting
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        // positive moves toward the end of the chapter; the deltas follow the content
        var forward = vertical && abs(dx) > abs(dy) ? dx : -dy
        if !event.hasPreciseScrollingDeltas {
            forward *= 10
        }

        if (forward > 0 && atEnd) || (forward < 0 && atStart) {
            overscroll += forward
        } else if forward != 0 {
            overscroll = 0
        }

        let threshold = CGFloat(max(coordinator.parent.userConfig.chapterSwipeDistance, 1))
        if overscroll > threshold {
            changeChapter(.forward)
        } else if overscroll < -threshold {
            changeChapter(.backward)
        }
        return false
    }

    private func changeChapter(_ direction: NavigationDirection) {
        overscroll = 0
        scrollEnded?.cancel()
        guard coordinator?.changeChapter(direction) == true else { return }
        // the new chapter reports its own edges once it restores
        atStart = true
        atEnd = false
    }
}
#endif
