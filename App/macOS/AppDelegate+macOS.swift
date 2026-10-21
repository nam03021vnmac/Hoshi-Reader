//
//  AppDelegate+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Platform.startMemoryPressureMonitor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// The Dock menu stands in for the iOS home-screen shortcuts.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for (title, type) in [
            (String(localized: "Books"), "de.manhhao.hoshi.books"),
            (String(localized: "Dictionary"), "de.manhhao.hoshi.dictionary"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(openShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = type
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openShortcut(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? String else { return }
        NSApp.activate()
        // SwiftUI names the window after its scene id
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("library") == true }?.makeKeyAndOrderFront(nil)
        ShortcutHandler.shared.pendingType = type
    }
}
#endif
