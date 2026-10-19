//
//  PlatformScenes.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The scene that holds the bookshelf.
///
/// On macOS it is a single `Window`. A `WindowGroup` there would let File > New Window
/// open a second library, and opening a file from Finder would spawn yet another window
/// whose bookshelf imports the same file again.
struct LibraryWindow<Content: View>: Scene {
    @ViewBuilder var content: () -> Content

    var body: some Scene {
        #if os(macOS)
        Window("Hoshi Reader", id: "library", content: content)
            .defaultSize(width: 1100, height: 760)
        #else
        WindowGroup(content: content)
        #endif
    }
}
