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

    /// Rebuilds the reader's web view whenever its layout changes. A macOS window resize
    /// changes the size on every frame, so there the rebuild waits until the size settles.
    func readerLayoutID<ID: Hashable>(_ id: ID) -> some View {
        #if os(macOS)
        modifier(SettledID(id: id))
        #else
        self.id(id)
        #endif
    }

    /// Runs `action` when Esc is pressed. On iOS this does nothing.
    func onEscapeKey(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Applies `.id(id)` once `id` has stopped changing for a moment.
private struct SettledID<ID: Hashable>: ViewModifier {
    let id: ID
    @State private var settledID: ID

    init(id: ID) {
        self.id = id
        _settledID = State(initialValue: id)
    }

    func body(content: Content) -> some View {
        content
            .id(settledID)
            .task(id: id) {
                guard id != settledID else { return }
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
                settledID = id
            }
    }
}
#endif

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
