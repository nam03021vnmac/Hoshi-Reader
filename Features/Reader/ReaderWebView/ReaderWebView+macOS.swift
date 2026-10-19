//
//  ReaderWebView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI

import WebKit

final class HoshiWKWebView: WKWebView {
    var onHighlightCreated: ((HighlightColor, HighlightData) -> Void)?
    var onHighlightUpdated: ((HighlightColor, UUID) -> Void)?
    var hasSelection: Bool = false
}

// TODO(macos): replace with an NSViewRepresentable that shares the Coordinator
// (click to look up, arrow keys and trackpad swipes to turn pages).
extension ReaderWebView: View {
    var body: some View {
        NotYetOnMacView("The paginated reader")
            .onAppear { onRestoreCompleted() }
    }
}

extension ReaderWebView.Coordinator {
    func scrollOrigin(of webView: WKWebView?) -> CGPoint {
        .zero
    }
}
#endif
