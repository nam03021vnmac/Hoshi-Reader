//
//  ReaderWebView+iOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(iOS)
import WebKit
import SwiftUI
import UIKit

final class HoshiWKWebView: WKWebView {
    var onHighlightCreated: ((HighlightColor, HighlightData) -> Void)?
    var onHighlightUpdated: ((HighlightColor, UUID) -> Void)?
    var hasSelection: Bool = false

    // https://stackoverflow.com/a/78488754
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard hasSelection else { return }
        let children = HighlightColor.allCases.map { color in
            let swatch = UIImage(systemName: "circle.fill")?.withTintColor(UIColor(color.swatch), renderingMode: .alwaysOriginal)
            return UIAction(title: color.rawValue.capitalized, image: swatch) { [weak self] _ in
                self?.createHighlight(color: color)
            }
        }
        let menu = UIMenu(
            title: "Highlight",
            image: UIImage(systemName: "highlighter"),
            options: [.displayAsPalette],
            preferredElementSize: .medium,
            children: children
        )
        builder.remove(menu: .learn)
        builder.insertSibling(menu, beforeMenu: .standardEdit)
    }
}

extension ReaderWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = makeConfiguration(coordinator: context.coordinator)
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = HoshiWKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        if UIDevice.current.userInterfaceIdiom == .pad {
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        }
        webView.scrollView.isScrollEnabled = false

        let swipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeLeft(_:)))
        swipeLeft.direction = .left
        swipeLeft.delegate = context.coordinator
        swipeLeft.cancelsTouchesInView = false
        swipeLeft.delaysTouchesEnded = false
        webView.addGestureRecognizer(swipeLeft)

        let swipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeRight(_:)))
        swipeRight.direction = .right
        swipeRight.delegate = context.coordinator
        swipeRight.cancelsTouchesInView = false
        swipeRight.delaysTouchesEnded = false
        webView.addGestureRecognizer(swipeRight)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.require(toFail: swipeLeft)
        tap.require(toFail: swipeRight)
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        webView.addGestureRecognizer(tap)

        prepare(webView, coordinator: context.coordinator)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        updateWebView(webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        dismantleWebView(webView, coordinator: coordinator)
    }
}

extension ReaderWebView.Coordinator: UIGestureRecognizerDelegate {
    /// How far the web view's scroll view is scrolled, which offsets the rects that JS reports.
    func scrollOrigin(of webView: WKWebView?) -> CGPoint {
        webView?.scrollView.bounds.origin ?? .zero
    }

    @objc func handleSwipeLeft(_ gesture: UISwipeGestureRecognizer) {
        navigate(parent.userConfig.verticalWriting ? .backward : .forward)
    }

    @objc func handleSwipeRight(_ gesture: UISwipeGestureRecognizer) {
        navigate(parent.userConfig.verticalWriting ? .forward : .backward)
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let webView = webView else {
            return
        }
        handleTap(at: gesture.location(in: webView))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if otherGestureRecognizer is UILongPressGestureRecognizer {
            return false
        }
        return true
    }
}
#endif
