//
//  ReaderWebView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI

// TODO(macos): replace with an NSViewRepresentable that shares the iOS Coordinator
// (click to look up, arrow keys and trackpad swipes to turn pages).
struct ReaderWebView: View {
    let userConfig: UserConfig
    let viewSize: CGSize
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
    var onPageTurn: (() -> Void)
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
        NotYetOnMacView("The paginated reader")
            .onAppear { onRestoreCompleted() }
    }
}
#endif
