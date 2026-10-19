//
//  PDFKitView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import PDFKit
import SwiftUI

// TODO(macos): replace with an NSViewRepresentable around PDFView. PDFKit is the
// same framework on macOS; only the tap and long-press recognizers need
// NSClickGestureRecognizer versions.
struct PDFKitView: View {
    let document: PDFDocument
    let initialPage: Int
    let displayMode: PDFDisplayMode
    let rightToLeft: Bool
    let onPageChanged: (Int) -> Void
    let onPageTap: (_ pageIndex: Int, _ pagePoint: CGPoint, _ viewPoint: CGPoint) -> Void
    let onTapOutside: (_ viewPoint: CGPoint) -> Void
    let onViewportChanged: () -> Void
    let onViewCreated: (PDFView, PDFHighlightOverlayProvider) -> Void

    var body: some View {
        NotYetOnMacView("The PDF reader")
    }
}
#endif
