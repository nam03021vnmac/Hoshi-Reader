//
//  MacSettingsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI

/// The ⌘, settings window. It shows the same screens as the in-app Settings tab.
///
/// It uses a sidebar rather than toolbar tabs: tabs share the window toolbar, so the
/// screens' own toolbar buttons (such as Dictionaries' import button) would land among them.
struct MacSettingsView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var section: MacSettingsSection? = .dictionaries

    var body: some View {
        NavigationSplitView {
            List(MacSettingsSection.allCases, selection: $section) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack {
                switch section ?? .dictionaries {
                case .dictionaries:
                    DictionaryView()
                case .anki:
                    AnkiView()
                case .appearance:
                    AppearanceView(userConfig: userConfig, showDismiss: false)
                case .advanced:
                    AdvancedView()
                case .about:
                    AboutView()
                }
            }
            // start each section at its root instead of keeping the previous section's pushed screens
            .id(section)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 680)
    }
}

private enum MacSettingsSection: CaseIterable, Identifiable {
    case dictionaries
    case anki
    case appearance
    case advanced
    case about

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .dictionaries: "Dictionaries"
        case .anki: "Anki"
        case .appearance: "Appearance"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .dictionaries: "character.book.closed.ja"
        case .anki: "tray.full"
        case .appearance: "paintpalette"
        case .advanced: "gearshape.2"
        case .about: "info.circle"
        }
    }
}
#endif
