//
//  MacSettingsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI

/// The Mac settings: the ⌘, window and the library's Settings tab. It shows the same screens
/// as the iOS Settings tab, with the Advanced screens listed in the sidebar instead of behind
/// a drill-down, like System Settings.
///
/// It uses a sidebar rather than toolbar tabs: tabs share the window toolbar, so the
/// screens' own toolbar buttons (such as Dictionaries' import button) would land among them.
/// The sidebar is laid out by hand rather than with a NavigationSplitView, which would take
/// over the window toolbar and, in the library, move its tab picker off center.
struct MacSettingsView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var section: MacSettingsSection? = .dictionaries

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                // a split view's sidebar is translucent; a lone sidebar list paints over the window instead
                .scrollContentBackground(.hidden)
            Divider()
            detail
        }
    }

    private var sidebar: some View {
        List(selection: $section) {
            ForEach(MacSettingsSection.groups, id: \.self) { group in
                Section {
                    ForEach(group) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var detail: some View {
        NavigationStack {
            switch section ?? .dictionaries {
            case .dictionaries:
                DictionaryView()
            case .anki:
                AnkiView()
            case .appearance:
                AppearanceView(userConfig: userConfig, showDismiss: false)
            case .audio:
                AudioView()
            case .sasayaki:
                SasayakiSettingsView()
            case .pdf:
                PDFSettingsView()
            case .sync:
                SyncView()
            case .ankiConnect:
                AnkiConnectView()
            case .backup:
                BackupView()
            case .about:
                AboutView()
            }
        }
        // start each section at its root instead of keeping the previous section's pushed screens
        .id(section)
    }
}

private enum MacSettingsSection: Identifiable {
    case dictionaries
    case anki
    case appearance
    case audio
    case sasayaki
    case pdf
    case sync
    case ankiConnect
    case backup
    case about

    /// The sidebar's sections, in order.
    static let groups: [[MacSettingsSection]] = [
        [.dictionaries, .anki, .appearance],
        [.audio, .sasayaki, .pdf],
        [.sync, .ankiConnect, .backup],
        [.about],
    ]

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .dictionaries: "Dictionaries"
        case .anki: "Anki"
        case .appearance: "Appearance"
        case .audio: "Audio"
        case .sasayaki: "Sasayaki"
        case .pdf: "PDF"
        case .sync: "ッツ Sync"
        case .ankiConnect: "AnkiConnect"
        case .backup: "Backup"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .dictionaries: "character.book.closed.ja"
        case .anki: "tray.full"
        case .appearance: "paintpalette"
        case .audio: "speaker.wave.2"
        case .sasayaki: "waveform"
        case .pdf: "doc.richtext"
        case .sync: "cloud"
        case .ankiConnect: "app.connected.to.app.below.fill"
        case .backup: "externaldrive"
        case .about: "info.circle"
        }
    }
}
#endif
