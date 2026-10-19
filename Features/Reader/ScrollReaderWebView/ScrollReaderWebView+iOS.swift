//
//  ScrollReaderWebView+iOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(iOS)
import WebKit
import SwiftUI
import UIKit

extension ScrollReaderWebView: UIViewRepresentable {
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
        webView.scrollView.delegate = context.coordinator
        webView.scrollView.alwaysBounceVertical = !userConfig.verticalWriting
        webView.scrollView.alwaysBounceHorizontal = userConfig.verticalWriting
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.scrollsToTop = false

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
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

extension ScrollReaderWebView.Coordinator: UIGestureRecognizerDelegate, UIScrollViewDelegate {
    /// How far the web view's scroll view is scrolled, which offsets the rects that JS reports.
    func scrollOrigin(of webView: WKWebView?) -> CGPoint {
        webView?.scrollView.bounds.origin ?? .zero
    }

    /// Scroll callbacks are turned off while a chapter loads or restores its position.
    func setScrollTracking(_ enabled: Bool) {
        webView?.scrollView.delegate = enabled ? self : nil
    }

    func removeDoubleTapZoom(from webView: WKWebView) {
        webView.scrollView.subviews.forEach { subview in
            subview.gestureRecognizers?.forEach { recognizer in
                if let tapRecognizer = recognizer as? UITapGestureRecognizer,
                   tapRecognizer.numberOfTapsRequired == 2,
                   tapRecognizer.numberOfTouchesRequired == 1 {
                    subview.removeGestureRecognizer(recognizer)
                }
            }
        }
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let webView = webView, !webView.scrollView.isDecelerating else {
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

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let vertical = parent.userConfig.verticalWriting
        let offset = vertical ? scrollView.contentOffset.x : scrollView.contentOffset.y
        let contentSize = vertical ? scrollView.contentSize.width : scrollView.contentSize.height
        let viewSize = vertical ? scrollView.bounds.width : scrollView.bounds.height
        let maxOffset = max(contentSize - viewSize, 0)
        let threshold = CGFloat(parent.userConfig.chapterSwipeDistance)

        let scrolledPastEnd = vertical ? offset < -threshold : offset > maxOffset + threshold
        let scrolledPastStart = vertical ? offset > maxOffset + threshold : offset < -threshold

        if scrolledPastEnd {
            changeChapter(.forward)
        } else if scrolledPastStart {
            changeChapter(.backward)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        handleScroll()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        handleScrollEnded()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            handleScrollEnded()
        }
    }
}
#endif
