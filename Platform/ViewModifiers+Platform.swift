//
//  ViewModifiers+Platform.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The container for a settings screen. iOS uses its usual inset grouped List. A macOS List
/// is a flat, sidebar-like list with checkboxes, so there it is a grouped Form instead, laid
/// out like System Settings: labels on the left, switches and values on the right.
struct SettingsList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        Form {
            content
        }
        .formStyle(.grouped)
        // let the translucent window show through behind the grouped rows
        .scrollContentBackground(.hidden)
        #else
        List {
            content
        }
        #endif
    }
}

/// A slider that moves in steps of `step`, like `Slider(value:in:step:)`.
///
/// On macOS a stepped Slider draws a tick mark for every step, and AppKit measures each one
/// whenever the slider is laid out. Fine steps, such as 100...800 by 10 or one per PDF page,
/// then stall the window for hundreds of milliseconds, so there the slider is continuous
/// and rounds what it writes to the nearest step instead.
struct SteppedSlider<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    @Binding var value: Value
    let bounds: ClosedRange<Value>
    let step: Value.Stride
    let onEditingChanged: (Bool) -> Void

    init(value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value.Stride, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.bounds = bounds
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        #if os(macOS)
        Slider(value: Binding(
            get: { value },
            set: { newValue in
                let snapped = snap(newValue)
                if snapped != value {
                    value = snapped
                }
            }
        ), in: bounds, onEditingChanged: onEditingChanged)
        #else
        Slider(value: $value, in: bounds, step: step, onEditingChanged: onEditingChanged)
        #endif
    }

    private func snap(_ newValue: Value) -> Value {
        let step = Value(step)
        let snapped = bounds.lowerBound + ((newValue - bounds.lowerBound) / step).rounded() * step
        return min(max(snapped, bounds.lowerBound), bounds.upperBound)
    }
}

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

    /// Styles a `SettingsList` section footer. macOS grouped forms align footers to the trailing
    /// edge, where they expect buttons, so explanatory text there is set leading and secondary
    /// like System Settings. iOS footers already look that way, so this does nothing there.
    func settingsFooter() -> some View {
        #if os(macOS)
        font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
extension View {
    /// Lets the desktop show through a window's background, like Finder and System Settings.
    /// Views that paint their own background, such as a book or a dictionary page, stay opaque.
    func translucentWindowBackground() -> some View {
        containerBackground(.thinMaterial, for: .window)
            // the toolbar keeps a material of its own so content scrolled under it is blurred out
            .toolbarBackground(.thinMaterial, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }
}

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
