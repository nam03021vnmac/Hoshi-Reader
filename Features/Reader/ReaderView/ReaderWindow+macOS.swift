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
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 1000))
        window.setFrameAutosaveName("ReaderWindow")
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
