//
//  MacCommands.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI

/// Menu bar commands. They route through `ShortcutHandler`, the same path
/// the iOS home-screen shortcuts use.
struct MacCommands: Commands {
    var body: some Commands {
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
    }
}
#endif
