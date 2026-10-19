//
//  MacCommands.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI

/// Menu bar commands. Books and Dictionary route through `ShortcutHandler`, the same
/// path the iOS home-screen shortcuts use; Import Books… is handled by the bookshelf.
struct MacCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Books…") {
                NotificationCenter.default.post(name: .importBooks, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button("Books") {
                ShortcutHandler.shared.pendingType = "de.manhhao.hoshi.books"
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Dictionary") {
                ShortcutHandler.shared.pendingType = "de.manhhao.hoshi.dictionary"
            }
            .keyboardShortcut("2", modifiers: .command)

            Divider()
        }

        // sent to whichever reader has the keyboard: a PDF zooms, an EPUB changes its font size
        CommandGroup(before: .toolbar) {
            Button("Zoom In") {
                NSApp.sendAction(#selector(ReaderZooming.zoomIn(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Zoom Out") {
                NSApp.sendAction(#selector(ReaderZooming.zoomOut(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Zoom to Fit") {
                NSApp.sendAction(#selector(ReaderZooming.zoomToFit(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()
        }
    }
}

/// The zoom actions the View menu sends up the responder chain.
@objc protocol ReaderZooming {
    func zoomIn(_ sender: Any?)
    func zoomOut(_ sender: Any?)
    @objc optional func zoomToFit(_ sender: Any?)
}
#endif
