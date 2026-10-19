//
//  ReaderWindow+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import AppKit
import SwiftUI

/// Opens the reader in its own window. On iOS this is a full-screen modal over the bookshelf.
@MainActor
final class ReaderWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onDismiss: (() -> Void)?

    func present<Content: View>(@ViewBuilder content: () -> Content, onDismiss: @escaping () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let dismiss: () -> Void = { [weak self] in self?.dismiss() }
        let host = NSHostingController(rootView: AnyView(content().environment(\.dismissReader, dismiss)))
        // the window keeps the frame set up below; the reader lays out once at that size
        // instead of at a throwaway size that loads the chapter twice
        host.sizingOptions = []

        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 1000
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: min(1000, visibleHeight)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("ReaderWindow") {
            window.center()
        }
        window.setFrameAutosaveName("ReaderWindow")
        host.view.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        window.contentViewController = host
        window.delegate = self

        self.window = window
        self.onDismiss = onDismiss
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss(onDismiss: (() -> Void)? = nil) {
        window?.close()
        onDismiss?()
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        let onDismiss = self.onDismiss
        self.onDismiss = nil
        onDismiss?()
    }
}
#endif
