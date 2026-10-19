//
//  PopupWebView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI
import AppKit
import WebKit

// The macOS WKWebView scrolls inside its own process and has no scroll view to add native
// buttons to, so the onScrollView… callbacks never fire here and each `.button-slot` draws
// its SF Symbol as a CSS mask instead. Clicks on a slot go through `popupButton` to the shared
// Coordinator, and right-clicking an audio slot opens the audio source menu as an NSMenu.
extension PopupWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let config = makeConfiguration(coordinator: context.coordinator)
        config.userContentController.add(context.coordinator.buttons, name: "popupButton")
        config.userContentController.addUserScript(WKUserScript(
            source: PopupButtons.buttonsJs,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let webView = PopupMacWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        updateWebView(webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "popupButton")
        dismantleWebView(webView, coordinator: coordinator)
    }
}

extension PopupWebView.Coordinator {
    /// Where the web view's content starts, in the web view's coordinates. macOS adds no content insets.
    func contentOrigin(of webView: WKWebView) -> CGPoint {
        .zero
    }
}

/// Removes the default context menu items that navigate the web view or open a new window,
/// since the popup is a single page loaded from a string.
private final class PopupMacWebView: WKWebView {
    private static let removedMenuItems: Set<String> = [
        "WKMenuItemIdentifierReload",
        "WKMenuItemIdentifierGoBack",
        "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow",
        "WKMenuItemIdentifierDownloadMedia",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.items.removeAll { item in
            item.identifier.map { Self.removedMenuItems.contains($0.rawValue) } ?? false
        }
        // drop the separators the removed items leave at the ends or next to each other
        var previousWasSeparator = true
        menu.items.removeAll { item in
            defer { previousWasSeparator = item.isSeparatorItem }
            return item.isSeparatorItem && previousWasSeparator
        }
        if menu.items.last?.isSeparatorItem == true {
            menu.items.removeLast()
        }
    }
}

/// Draws the button for each `.button-slot` inside the page and forwards clicks on it.
final class PopupButtons: NSObject, WKScriptMessageHandler {
    fileprivate static let buttonsJs = """
    (function() {
        const style = document.createElement('style');
        style.textContent = `
            .button-slot[data-symbol] {
                background-color: rgba(60, 60, 67, 0.6);
                -webkit-mask-position: center;
                -webkit-mask-repeat: no-repeat;
                -webkit-user-select: none;
            }
            @media (prefers-color-scheme: dark) {
                .button-slot[data-symbol] { background-color: rgba(235, 235, 245, 0.6); }
            }
        `;
        document.head.appendChild(style);

        window.hoshiButtons = {
            apply(buttons) {
                for (const button of buttons) {
                    // popup.js creates audio slots without a slot index
                    const slot = button.kind === 'audio'
                        ? getButtonSlots('audio', button.entryIndex)[0]
                        : getButtonSlot(button.kind, button.entryIndex, button.slotIndex);
                    if (!slot) {
                        continue;
                    }
                    if (slot.dataset.symbol !== button.symbol) {
                        slot.dataset.symbol = button.symbol;
                        slot.style.webkitMaskImage = `url("${button.image}")`;
                        slot.style.webkitMaskSize = `${button.width}px ${button.height}px`;
                    }
                    slot.style.opacity = button.opacity;
                }
            }
        };

        const slotFor = (e) => e.target instanceof Element ? e.target.closest('.button-slot[data-symbol]') : null;
        const post = (slot, extra) => webkit.messageHandlers.popupButton.postMessage({
            kind: slot.dataset.kind,
            entryIndex: Number(slot.dataset.entryIndex),
            // audio slots have no slot index
            slotIndex: Number(slot.dataset.slotIndex) || 0,
            ...extra
        });
        // a button press must not clear the selection that mining reads, or reach the
        // entries container, which treats a click outside a glossary as a tap outside
        const swallow = (e) => {
            const slot = slotFor(e);
            if (slot) {
                e.preventDefault();
                e.stopPropagation();
            }
            return slot;
        };
        window.addEventListener('mousedown', swallow, true);
        window.addEventListener('mouseup', swallow, true);
        window.addEventListener('click', (e) => {
            const slot = swallow(e);
            if (slot && slot.dataset.enabled !== 'false') {
                post(slot, { menu: false });
            }
        }, true);
        window.addEventListener('contextmenu', (e) => {
            const slot = swallow(e);
            if (slot?.dataset.kind === 'audio') {
                post(slot, { menu: true, x: e.clientX, y: e.clientY });
            }
        }, true);
    })();
    """

    private struct SymbolMask {
        let dataURL: String
        let size: CGSize
    }

    private weak var coordinator: PopupWebView.Coordinator?
    private var masks: [String: SymbolMask] = [:]

    init(coordinator: PopupWebView.Coordinator) {
        self.coordinator = coordinator
    }

    func update(_ slots: [PopupButtonSlot], in webView: WKWebView) {
        guard let coordinator else { return }
        let buttons: [[String: Any]] = slots.compactMap { slot in
            guard let symbol = coordinator.symbol(for: slot),
                  let mask = mask(name: symbol.name, pointSize: symbol.pointSize) else {
                return nil
            }
            return [
                "kind": slot.kind,
                "entryIndex": slot.entryIndex,
                "slotIndex": slot.slotIndex,
                "symbol": "\(symbol.name)@\(symbol.pointSize)",
                "image": mask.dataURL,
                "width": mask.size.width,
                "height": mask.size.height,
                "opacity": slot.isEnabled ? (slot.kind == "note" ? 0.58 : 0.85) : 0.3,
            ]
        }
        webView.callAsyncJavaScript(
            "window.hoshiButtons?.apply(buttons)",
            arguments: ["buttons": buttons],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "popupButton",
              let body = message.body as? [String: Any],
              let kind = body["kind"] as? String,
              let entryIndex = body["entryIndex"] as? Int,
              let slotIndex = body["slotIndex"] as? Int else {
            return
        }

        if body["menu"] as? Bool == true, let webView = message.webView,
           let x = body["x"] as? CGFloat, let y = body["y"] as? CGFloat {
            let point = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
            Task { await showAudioMenu(entryIndex: entryIndex, at: point, in: webView) }
        } else {
            coordinator?.buttonTapped(kind: kind, entryIndex: entryIndex, slotIndex: slotIndex)
        }
    }

    private func showAudioMenu(entryIndex: Int, at point: NSPoint, in webView: WKWebView) async {
        guard let coordinator else { return }
        let audioMenu = await coordinator.audioMenu(entryIndex: entryIndex)

        let menu = NSMenu()
        if audioMenu.names.isEmpty {
            let item = NSMenuItem(title: String(localized: "No audio found"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for (index, name) in audioMenu.names.enumerated() {
            let item = NSMenuItem(title: name, action: #selector(audioSourceSelected(_:)), keyEquivalent: "")
            item.target = self
            item.state = index == audioMenu.selected ? .on : .off
            item.representedObject = [entryIndex, index]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: webView)
    }

    @objc private func audioSourceSelected(_ sender: NSMenuItem) {
        guard let indices = sender.representedObject as? [Int], indices.count == 2 else { return }
        coordinator?.playAudio(entryIndex: indices[0], sourceIndex: indices[1])
    }

    /// The symbol rendered as a PNG for `-webkit-mask-image`. Only its alpha matters,
    /// so the page tints it to match the iOS buttons' secondary label color.
    private func mask(name: String, pointSize: CGFloat) -> SymbolMask? {
        let key = "\(name)@\(pointSize)"
        if let mask = masks[key] {
            return mask
        }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)) else {
            return nil
        }

        let size = image.size
        // 3x keeps the edges sharp on Retina displays and when the page is zoomed
        let scale: CGFloat = 3
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int((size.width * scale).rounded(.up)),
                pixelsHigh: Int((size.height * scale).rounded(.up)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else {
            return nil
        }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        let mask = SymbolMask(dataURL: "data:image/png;base64," + png.base64EncodedString(), size: size)
        masks[key] = mask
        return mask
    }
}
#endif
