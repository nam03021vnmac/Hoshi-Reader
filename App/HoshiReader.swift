//
//  HoshiReader.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import WebKit

@main
struct HoshiReaderApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var userConfig = UserConfig.shared
    @State private var pendingImportURL: URL?
    @State private var pendingRemoteImportURL: URL?
    @State private var pendingLookup: String?
    @State private var pendingTab: Int?
    @State private var didFinishLaunch = BookStorage.migrationsComplete
    private var shortcutHandler = ShortcutHandler.shared
    
    private func startup() async {
        TokenStorage.clearOldKeys()
        await Task.detached(priority: .userInitiated) {
            BookStorage.migrateFromDocuments()
            BookStorage.migrateBooks()
        }.value
        didFinishLaunch = true
        _ = DictionaryManager.shared
        _ = GoogleDriveHandler.shared
        WebViewPreloader.shared.warmup()
    }
    
    var body: some Scene {
        LibraryWindow {
            Group {
                if didFinishLaunch {
                    BookshelfView(
                        pendingImportURL: $pendingImportURL,
                        pendingRemoteImportURL: $pendingRemoteImportURL,
                        pendingLookup: $pendingLookup,
                        pendingTab: $pendingTab
                    )
                } else {
                    LaunchView()
                }
            }
            .environment(userConfig)
            .preferredColorScheme(userConfig.theme == .custom ? userConfig.uiTheme.colorScheme : (userConfig.theme == .sepia && userConfig.sepiaInvertInDark ? nil : userConfig.theme.colorScheme))
            .task {
                await startup()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    LocalFileServer.shared.endBackgroundTask()
                    Task { @MainActor in
                        LocalFileServer.shared.setAudioServer(enabled: userConfig.enableLocalAudio)
                    }
                    if userConfig.autoUpdateDictionaries {
                        DictionaryManager.shared.autoUpdateDictionaries()
                    }
                case .background:
                    LocalFileServer.shared.startBackgroundTask()
                default:
                    break
                }
            }
            .onChange(of: userConfig.enableLocalAudio) { _, _ in
                LocalFileServer.shared.setAudioServer(enabled: userConfig.enableLocalAudio)
            }
            .onOpenURL { url in
                handleURL(url)
            }
            .onChange(of: shortcutHandler.pendingType, initial: true) { _, type in
                switch type {
                case "de.manhhao.hoshi.books":
                    pendingTab = 0
                case "de.manhhao.hoshi.dictionary":
                    pendingLookup = ""
                default:
                    break
                }
                shortcutHandler.pendingType = nil
            }
        }
        #if os(macOS)
        .commands {
            MacCommands()
        }
        #endif

        #if os(macOS)
        // a Window rather than a Settings scene, which gets the preferences toolbar: that gives
        // each screen's buttons a centered row of their own instead of the library's compact
        // toolbar. MacCommands opens it with ⌘,.
        Window("Settings", id: MacCommands.settingsWindowID) {
            MacSettingsView()
                .frame(minWidth: 720, minHeight: 520)
                .translucentWindowBackground()
                .environment(userConfig)
        }
        .defaultSize(width: 820, height: 680)
        .windowToolbarStyle(.unified)
        // keep it out of the Window menu, like a settings window
        .commandsRemoved()
        #endif
    }
    
    private func handleURL(_ url: URL) {
        if url.scheme == "hoshi" {
            if url.host == "ankiFetch" {
                AnkiManager.shared.fetch()
            } else if url.host == "ankiSuccess" {
                LocalFileServer.shared.clearMedia()
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let expression = components.queryItems?.first(where: { $0.name == "expression" })?.value {
                    AnkiManager.shared.addWord(expression)
                }
            } else if url.host == "search" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                pendingLookup = components?.queryItems?.first(where: { $0.name == "text" })?.value ?? ""
            } else if url.host == "open", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let urlString = components.queryItems?.first(where: { $0.name == "url" })?.value,
                      let remoteURL = URL(string: urlString) {
                pendingRemoteImportURL = remoteURL
            }
        } else if url.isFileURL {
            pendingImportURL = url
        }
    }
}

@Observable
class ShortcutHandler {
    static let shared = ShortcutHandler()
    var pendingType: String?
}

class WebViewPreloader {
    static let shared = WebViewPreloader()
    private var dummy: WKWebView?
    func warmup() {
        DispatchQueue.main.async {
            self.dummy = WKWebView(frame: .zero)
            self.dummy?.loadHTMLString("", baseURL: nil)
        }
    }
    
    func close() {
        guard dummy != nil else {
            return
        }
        DispatchQueue.main.async {
            self.dummy = nil
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            ProgressView()
        }
    }
}
