//
//  NSMenu+WebView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import AppKit

extension NSMenu {
    private static let webViewNavigationItems: Set<String> = [
        "WKMenuItemIdentifierReload",
        "WKMenuItemIdentifierGoBack",
        "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierOpenLink",
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow",
        "WKMenuItemIdentifierDownloadMedia",
    ]

    /// Removes the items a WKWebView context menu adds for browsing (Reload, Back/Forward,
    /// opening links or images in a new window, downloads), which do nothing useful for
    /// pages the app renders itself. Call it from `willOpenMenu(_:with:)`.
    func removeWebViewNavigationItems() {
        items.removeAll { item in
            item.identifier.map { Self.webViewNavigationItems.contains($0.rawValue) } ?? false
        }
        // drop the separators the removed items leave at the ends or next to each other
        var previousWasSeparator = true
        items.removeAll { item in
            defer { previousWasSeparator = item.isSeparatorItem }
            return item.isSeparatorItem && previousWasSeparator
        }
        if items.last?.isSeparatorItem == true {
            removeItem(at: items.count - 1)
        }
    }
}
#endif
