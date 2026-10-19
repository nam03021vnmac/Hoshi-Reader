//
//  PopupWebView+iOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(iOS)
import SwiftUI
import UIKit
import WebKit

extension PopupWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeConfiguration(coordinator: context.coordinator))
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = scrollViewBounces
        webView.scrollView.keyboardDismissMode = .onDrag
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.delegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        updateWebView(webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        dismantleWebView(webView, coordinator: coordinator)
    }
}

extension PopupWebView.Coordinator: UIScrollViewDelegate {
    /// Where the web view's content starts, in the web view's coordinates.
    func contentOrigin(of webView: WKWebView) -> CGPoint {
        let adjustedInset = webView.scrollView.adjustedContentInset
        return CGPoint(x: adjustedInset.left, y: adjustedInset.top)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        parent.onScrollViewOffsetChanged?(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        guard scrollView.contentOffset.x != 0 else { return }
        scrollView.contentOffset.x = 0
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        parent.onScrollViewWillBeginDragging?()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        parent.onScrollViewDidEndDragging?()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        parent.onScrollViewDidEndDecelerating?()
    }
}

/// UIButtons placed in the web view's scroll view over each `.button-slot`, so they scroll with the content.
final class PopupButtons: NSObject {
    private weak var coordinator: PopupWebView.Coordinator?
    private var buttons: [String: UIButton] = [:]
    private var buttonActions: [UIButton: (kind: String, entryIndex: Int, slotIndex: Int)] = [:]

    init(coordinator: PopupWebView.Coordinator) {
        self.coordinator = coordinator
    }

    func update(_ slots: [PopupButtonSlot], in webView: WKWebView) {
        guard let coordinator else { return }
        var activeKeys = Set<String>()

        for slot in slots {
            let key = slot.key
            activeKeys.insert(key)

            let button: UIButton
            if let existing = buttons[key] {
                button = existing
            } else {
                button = UIButton(type: .system)
                button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
                button.tintColor = .secondaryLabel
                if slot.kind == "audio" {
                    let entryIndex = slot.entryIndex
                    button.showsMenuAsPrimaryAction = false
                    button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                        Task { @MainActor in
                            completion(await self?.audioMenuElements(entryIndex: entryIndex) ?? [])
                        }
                    }])
                }
                buttons[key] = button
                webView.scrollView.addSubview(button)
            }

            buttonActions[button] = (slot.kind, slot.entryIndex, slot.slotIndex)
            button.frame = slot.frame
            let image = coordinator.symbol(for: slot).flatMap { symbol in
                UIImage(systemName: symbol.name, withConfiguration: UIImage.SymbolConfiguration(pointSize: symbol.pointSize, weight: .medium))
            }
            button.setImage(image, for: .normal)
            button.isEnabled = slot.isEnabled
            button.alpha = button.isEnabled ? (slot.kind == "note" ? 0.58 : 0.85) : 0.55
        }

        for key in buttons.keys.filter({ !activeKeys.contains($0) }) {
            if let button = buttons.removeValue(forKey: key) {
                buttonActions.removeValue(forKey: button)
                button.removeFromSuperview()
            }
        }
    }

    private func audioMenuElements(entryIndex: Int) async -> [UIMenuElement] {
        guard let coordinator else { return [] }
        let menu = await coordinator.audioMenu(entryIndex: entryIndex)

        guard !menu.names.isEmpty else {
            return [UIAction(title: String(localized: "No audio found"), attributes: .disabled) { _ in }]
        }

        return menu.names.enumerated().map { index, name in
            UIAction(title: name, state: index == menu.selected ? .on : .off) { [weak coordinator] _ in
                coordinator?.playAudio(entryIndex: entryIndex, sourceIndex: index)
            }
        }
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        guard let action = buttonActions[sender] else { return }
        coordinator?.buttonTapped(kind: action.kind, entryIndex: action.entryIndex, slotIndex: action.slotIndex)
    }
}
#endif
