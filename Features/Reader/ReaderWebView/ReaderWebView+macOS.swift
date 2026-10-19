//
//  ReaderWebView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// Keyboard and scroll wheel input that a reader handles before WebKit sees it.
@MainActor
protocol ReaderInputHandling: AnyObject {
    /// Returns true when the event was handled and WebKit should not get it.
    func keyDown(with event: NSEvent) -> Bool
    /// Returns true when the event was handled and WebKit should not scroll.
    func scrollWheel(with event: NSEvent) -> Bool
}

/// The web view behind both readers. Clicks reach the Coordinator through `readerClick`
/// messages from `clickScript`; keys and the scroll wheel go to `inputHandler` first; and
/// right-clicking a selection adds a Highlight submenu to WebKit's context menu.
final class HoshiWKWebView: WKWebView {
    var onHighlightCreated: ((HighlightColor, HighlightData) -> Void)?
    var onHighlightUpdated: ((HighlightColor, UUID) -> Void)?
    var hasSelection: Bool = false
    var inputHandler: ReaderInputHandling?

    /// Posts a `readerClick` message for each plain left click, in the same coordinates that
    /// `hoshiSelection.selectText` takes. A click that only clears a selection, or ends a
    /// drag that selected text, isn't posted. Double clicks don't select words natively, since
    /// a click already looks the word up (and a double click seeks Sasayaki audio).
    static let clickScript = """
    (function() {
        let hadSelection = false;
        document.addEventListener('mousedown', event => {
            if (event.button !== 0) {
                return;
            }
            const selection = window.getSelection();
            hadSelection = !!selection && !selection.isCollapsed;
            if (event.detail > 1) {
                event.preventDefault();
            }
        }, true);
        document.addEventListener('click', event => {
            if (event.button !== 0 || event.metaKey || event.ctrlKey || hadSelection) {
                return;
            }
            const selection = window.getSelection();
            if (selection && !selection.isCollapsed) {
                return;
            }
            webkit.messageHandlers.readerClick.postMessage({ x: event.clientX, y: event.clientY });
        });
    })();
    """

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // take the keyboard right away so the arrow keys turn pages without clicking first
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if inputHandler?.keyDown(with: event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if inputHandler?.scrollWheel(with: event) == true {
            return
        }
        super.scrollWheel(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.removeWebViewNavigationItems()

        // WebKit only offers Copy when text is selected
        guard menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) else {
            return
        }
        let colors = NSMenu(title: "Highlight")
        for color in HighlightColor.allCases {
            let item = NSMenuItem(title: color.rawValue.capitalized, action: #selector(highlightSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            // a colored dot in the title, since this menu doesn't draw item images
            let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: NSColor(color.swatch)])
            title.append(NSAttributedString(string: item.title))
            item.attributedTitle = title
            colors.addItem(item)
        }
        let highlight = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
        highlight.submenu = colors
        menu.insertItem(highlight, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func highlightSelection(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let color = HighlightColor(rawValue: rawValue) else {
            return
        }
        createHighlight(color: color)
    }
}

/// Forwards script messages to a closure, so a message handler doesn't have to be the Coordinator.
final class ReaderScriptMessageRelay: NSObject, WKScriptMessageHandler {
    private let handler: (WKScriptMessage) -> Void

    init(_ handler: @escaping (WKScriptMessage) -> Void) {
        self.handler = handler
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        handler(message)
    }
}

extension ReaderWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let input = PagedReaderInput(coordinator: coordinator)
        let config = makeConfiguration(coordinator: coordinator)
        config.userContentController.add(ReaderScriptMessageRelay { [weak coordinator] message in
            guard let body = message.body as? [String: Any],
                  let x = body["x"] as? CGFloat,
                  let y = body["y"] as? CGFloat else {
                return
            }
            coordinator?.handleTap(at: CGPoint(x: x, y: y))
        }, name: "readerClick")
        config.userContentController.addUserScript(WKUserScript(
            source: HoshiWKWebView.clickScript,
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
        dismantleWebView(webView, coordinator: coordinator)
    }
}

extension ReaderWebView.Coordinator {
    /// The macOS web view has no scroll view; the page itself is never scrolled by the user.
    func scrollOrigin(of webView: WKWebView?) -> CGPoint {
        .zero
    }
}

/// Turns pages with the keyboard, the scroll wheel and trackpad swipes.
@MainActor
private final class PagedReaderInput: ReaderInputHandling {
    private weak var coordinator: ReaderWebView.Coordinator?
    /// How far a trackpad swipe moves before it turns the page.
    private let swipeThreshold: CGFloat = 30
    /// A mouse wheel turns one page per burst of events. With smooth scrolling, a single
    /// click arrives as a stream of small deltas, so a burst ends after a pause, or after
    /// `wheelRepeatInterval` while the wheel keeps spinning.
    private let wheelPause: TimeInterval = 0.15
    private let wheelRepeatInterval: TimeInterval = 0.5
    private var swipeDelta: CGSize = .zero
    private var swipeHandled = false
    private var lastWheelEvent: TimeInterval = 0
    private var lastWheelTurn: TimeInterval = 0
    private var wheelBurstTurned = false

    init(coordinator: ReaderWebView.Coordinator) {
        self.coordinator = coordinator
    }

    func keyDown(with event: NSEvent) -> Bool {
        guard let coordinator,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        let vertical = coordinator.parent.userConfig.verticalWriting
        let direction: NavigationDirection
        switch event.specialKey {
        case .leftArrow:
            direction = vertical ? .forward : .backward
        case .rightArrow:
            direction = vertical ? .backward : .forward
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
        coordinator.navigate(direction)
        return true
    }

    func scrollWheel(with event: NSEvent) -> Bool {
        // the page never scrolls, so WebKit gets no wheel events at all
        guard let coordinator, event.momentumPhase.isEmpty else {
            return true
        }

        if event.phase.isEmpty {
            // a mouse wheel
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastWheelEvent > wheelPause {
                wheelBurstTurned = false
            }
            lastWheelEvent = now
            guard !wheelBurstTurned || now - lastWheelTurn > wheelRepeatInterval,
                  let direction = direction(for: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), in: coordinator) else {
                return true
            }
            wheelBurstTurned = true
            lastWheelTurn = now
            coordinator.navigate(direction)
            return true
        }

        if event.phase.contains(.began) {
            swipeDelta = .zero
            swipeHandled = false
        }
        swipeDelta.width += event.scrollingDeltaX
        swipeDelta.height += event.scrollingDeltaY
        guard !swipeHandled,
              max(abs(swipeDelta.width), abs(swipeDelta.height)) >= swipeThreshold,
              let direction = direction(for: swipeDelta, in: coordinator) else {
            return true
        }
        swipeHandled = true
        coordinator.navigate(direction)
        return true
    }

    /// Maps a scroll along its main axis to a page turn. The deltas follow the content, so a
    /// leftward swipe acts like the swipe left gesture on iOS, and scrolling down goes forward.
    private func direction(for delta: CGSize, in coordinator: ReaderWebView.Coordinator) -> NavigationDirection? {
        let vertical = coordinator.parent.userConfig.verticalWriting
        if abs(delta.width) > abs(delta.height) {
            return (delta.width < 0) != vertical ? .forward : .backward
        }
        if delta.height != 0 {
            return delta.height < 0 ? .forward : .backward
        }
        return nil
    }
}
#endif
