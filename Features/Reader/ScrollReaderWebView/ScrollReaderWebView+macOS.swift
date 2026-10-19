//
//  ScrollReaderWebView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI

// TODO(macos): replace with an NSViewRepresentable. Chapter changes at the scroll
// edges and progress updates come from UIScrollViewDelegate on iOS, so on macOS
// they need to come from scroll events in scrollreader.js.
struct ScrollReaderWebView: View {
    let userConfig: UserConfig
    let viewportWidth: Int
    let bridge: WebViewBridge
    let textColor: String?
    let sasayakiTextColor: Color
    let sasayakiBackgroundColor: Color
    var onNextChapter: () -> Bool
    var onPreviousChapter: () -> Bool
    var onSaveBookmark: (Double) -> Void
    var onInternalLink: (URL) -> Bool
    var onInternalJump: (Double) -> Void
    var onTextSelected: ((SelectionData) -> Int?)
    var onTapOutside: (() -> Void)
    var onScroll: (() -> Void)
    var onProgressChanged: ((Double) -> Void)
    var onRestoreCompleted: (() -> Void)
    var onProcessTerminated: (() -> Void)
    var onHighlightCreated: (HighlightColor, HighlightData) -> Void
    var onHighlightUpdated: (HighlightColor, UUID) -> Void
    var onImageTapped: (URL) -> Void
    var doubleTapSeekEnabled: Bool = false
    var canSeekText: (Int) -> Bool = { _ in false }
    var onDoubleTapText: (Int) -> Bool = { _ in false }
    let maxSelectionLength: Int = 16

    var body: some View {
        NotYetOnMacView("The scrolling reader")
            .onAppear { onRestoreCompleted() }
    }
}
#endif
