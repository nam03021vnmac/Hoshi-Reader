//
//  ViewModifiers+Platform.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

extension View {
    /// macOS lists have no swipe-to-delete or edit mode, so a row there gets a Delete item
    /// in its context menu instead. On iOS this does nothing; `.onDelete` already covers it.
    func macDeleteMenu(disabled: Bool = false, perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        contextMenu {
            Button("Delete", role: .destructive, action: action)
                .disabled(disabled)
        }
        #else
        self
        #endif
    }

    /// macOS sheets size themselves to their content, which collapses a List or Form
    /// to a sliver. iOS sheets already fill the screen, so this does nothing there.
    func sheetFrame(minWidth: CGFloat = 480, minHeight: CGFloat = 520) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The button that closes a sheet, such as Done. iOS puts it in the navigation bar. macOS
    /// sheets have no navigation bar and only show confirmation, cancellation and destructive actions.
    static var sheetDismiss: ToolbarItemPlacement {
        #if os(macOS)
        .confirmationAction
        #else
        .topBarTrailing
        #endif
    }

    /// A destructive button in a sheet, such as Reset.
    static var sheetDestructive: ToolbarItemPlacement {
        #if os(macOS)
        .destructiveAction
        #else
        .topBarLeading
        #endif
    }
}
