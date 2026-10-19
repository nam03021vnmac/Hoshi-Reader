//
//  ScrollReaderWebView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI

import WebKit

// TODO(macos): replace with an NSViewRepresentable. Chapter changes at the scroll
// edges and progress updates come from UIScrollViewDelegate on iOS, so on macOS
// they need to come from scroll events in scrollreader.js.
extension ScrollReaderWebView: View {
    var body: some View {
        NotYetOnMacView("The scrolling reader")
            .onAppear { onRestoreCompleted() }
    }
}

extension ScrollReaderWebView.Coordinator {
    func scrollOrigin(of webView: WKWebView?) -> CGPoint {
        .zero
    }

    func setScrollTracking(_ enabled: Bool) {}

    func removeDoubleTapZoom(from webView: WKWebView) {}
}
#endif
