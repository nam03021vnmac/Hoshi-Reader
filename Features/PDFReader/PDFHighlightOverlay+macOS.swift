//
//  PDFHighlightOverlay+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import PDFKit

// TODO(macos): PDFPageOverlayViewProvider is available on macOS too. Port
// PDFHighlightOverlayView to NSView (layer-backed, needsLayout instead of
// setNeedsLayout) and share the provider with iOS.
final class PDFHighlightOverlayProvider: NSObject {
    weak var pdfView: PDFView?
    var color: PlatformColor = .controlAccentColor

    func setHighlight(pageIndex: Int, rects: [CGRect]) {}
    func clear() {}
    func setBoxes(_ boxes: PDFTextBoxes, pageIndex: Int) {}
    func clearBoxes() {}
    func refreshLayout() {}
}
#endif
