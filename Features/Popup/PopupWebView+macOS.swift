//
//  PopupWebView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI

// TODO(macos): replace with an NSViewRepresentable that shares the iOS Coordinator's
// message handling. Only the mine-button UIMenu and the UIScrollViewDelegate callbacks
// need AppKit versions.
struct PopupWebView: View {
    let content: String
    let position: CGPoint
    var scale: CGFloat = 1.0
    var clearSelection: Bool
    var dictionaryStyles: [String: String] = [:]
    var lookupEntries: [[String: Any]] = []
    var scanNonJapaneseText: Bool = true
    var scanLength: Int = 16
    var backTrigger: Bool = false
    var forwardTrigger: Bool = false
    var onMine: (([String: String], UUID) async -> Bool)? = nil
    var onTextSelected: ((SelectionData) -> Int?)? = nil
    var onTapOutside: (() -> Void)? = nil
    var onSwipeDismiss: (() -> Void)? = nil
    var onRedirect: ((String) -> [[String: Any]])? = nil
    var onKanjiRedirect: ((String) -> [String: Any]?)? = nil
    var scrollViewBounces: Bool = false
    var onScrollViewOffsetChanged: ((CGFloat) -> Void)? = nil
    var onScrollViewWillBeginDragging: (() -> Void)? = nil
    var onScrollViewDidEndDragging: (() -> Void)? = nil
    var onScrollViewDidEndDecelerating: (() -> Void)? = nil

    var body: some View {
        NotYetOnMacView("Dictionary results")
    }
}
#endif
