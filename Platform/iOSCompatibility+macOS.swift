//
//  iOSCompatibility+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

// macOS stand-ins for iOS-only SwiftUI modifiers and UIKit color names.
// They let the shared views compile unchanged on macOS. Each one is a no-op
// or maps to the closest AppKit equivalent; none of them exist on iOS.

#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Modifiers that have no meaning on macOS

enum NavigationBarItem {
    enum TitleDisplayMode {
        case automatic
        case inline
        case large
    }
}

enum UIKeyboardType {
    case `default`
    case numberPad
    case decimalPad
    case URL
}

struct TextInputAutocapitalization {
    static let never = TextInputAutocapitalization()
    static let words = TextInputAutocapitalization()
    static let sentences = TextInputAutocapitalization()
    static let characters = TextInputAutocapitalization()
}

extension View {
    func navigationBarTitleDisplayMode(_ displayMode: NavigationBarItem.TitleDisplayMode) -> some View {
        self
    }

    func keyboardType(_ type: UIKeyboardType) -> some View {
        self
    }

    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View {
        self
    }

    func statusBarHidden(_ hidden: Bool = true) -> some View {
        self
    }
}

/// macOS lists reorder by dragging and delete with the Delete key without an edit mode.
struct EditButton: View {
    var body: some View {
        EmptyView()
    }
}

// MARK: - Toolbar and search placements

extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}

enum MacSearchDrawerDisplayMode {
    case automatic
    case always
}

extension SearchFieldPlacement {
    static func navigationBarDrawer(displayMode: MacSearchDrawerDisplayMode) -> SearchFieldPlacement {
        .toolbar
    }
}

// MARK: - List and picker styles

extension ListStyle where Self == InsetListStyle {
    static var insetGrouped: InsetListStyle { .inset }
}

extension PickerStyle where Self == MenuPickerStyle {
    static var wheel: MenuPickerStyle { .menu }
}

// MARK: - UIKit system color names

extension NSColor {
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var systemGray4: NSColor { .systemGray.withAlphaComponent(0.5) }
    static var systemGray5: NSColor { .systemGray.withAlphaComponent(0.25) }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var tintColor: NSColor { .controlAccentColor }
}

extension NSView {
    /// UIKit's name for `alphaValue`, so shared code can hide and fade in web views.
    var alpha: CGFloat {
        get { alphaValue }
        set { alphaValue = newValue }
    }

    /// UIKit's name for `needsLayout = true`.
    func setNeedsLayout() {
        needsLayout = true
    }
}

extension Color {
    init(uiColor: NSColor) {
        self.init(nsColor: uiColor)
    }
}
#endif
