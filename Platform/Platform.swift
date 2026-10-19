//
//  Platform.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import AuthenticationServices

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app-level services that differ between UIKit and AppKit.
/// Shared code calls these instead of `UIApplication`, `UIDevice` or `UIPasteboard`.
enum Platform {
    /// iPad or Mac: screens with room for more than a phone layout.
    static var isLargeDevice: Bool {
        #if os(macOS)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    static var topSafeArea: CGFloat {
        #if os(macOS)
        0
        #else
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?
            .safeAreaInsets.top ?? 0
        #endif
    }

    static var bottomSafeArea: CGFloat {
        #if os(macOS)
        0
        #else
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?
            .safeAreaInsets.bottom ?? 0
        #endif
    }

    static var presentationAnchor: ASPresentationAnchor {
        #if os(macOS)
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
        #else
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        guard let windowScene else {
            return UIWindow()
        }
        return windowScene.keyWindow ?? windowScene.windows.first ?? UIWindow(windowScene: windowScene)
        #endif
    }

    // MARK: - URLs

    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    @discardableResult
    static func open(_ url: URL) async -> Bool {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        await UIApplication.shared.open(url)
        #endif
    }

    // MARK: - Pasteboard

    static func pasteboardData(forType type: String) -> Data? {
        #if os(macOS)
        NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(type))
        #else
        UIPasteboard.general.data(forPasteboardType: type)
        #endif
    }

    static func setPasteboardData(_ data: Data, forType type: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(type))
        #else
        UIPasteboard.general.setData(data, forPasteboardType: type)
        #endif
    }

    // MARK: - Background work

    /// Mac apps keep running when they lose focus, so background tasks are a no-op there.
    struct BackgroundTaskID: Equatable {
        static let invalid = BackgroundTaskID()
        #if os(iOS)
        fileprivate var identifier: UIBackgroundTaskIdentifier = .invalid
        #endif
    }

    static func beginBackgroundTask(expirationHandler: (@MainActor @Sendable () -> Void)? = nil) -> BackgroundTaskID {
        #if os(macOS)
        .invalid
        #else
        BackgroundTaskID(identifier: UIApplication.shared.beginBackgroundTask(expirationHandler: expirationHandler))
        #endif
    }

    static func endBackgroundTask(_ task: BackgroundTaskID) {
        #if os(iOS)
        UIApplication.shared.endBackgroundTask(task.identifier)
        #endif
    }

    // MARK: - Display sleep

    #if os(macOS)
    private static var idleActivity: NSObjectProtocol?
    #endif

    static var isIdleTimerDisabled: Bool {
        get {
            #if os(macOS)
            idleActivity != nil
            #else
            UIApplication.shared.isIdleTimerDisabled
            #endif
        }
        set {
            #if os(macOS)
            if newValue, idleActivity == nil {
                idleActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated],
                    reason: "Audiobook playback"
                )
            } else if !newValue, let activity = idleActivity {
                ProcessInfo.processInfo.endActivity(activity)
                idleActivity = nil
            }
            #else
            UIApplication.shared.isIdleTimerDisabled = newValue
            #endif
        }
    }

    // MARK: - App lifecycle notifications

    #if os(macOS)
    nonisolated static let didBecomeActiveNotification = NSApplication.didBecomeActiveNotification
    nonisolated static let willResignActiveNotification = NSApplication.willResignActiveNotification
    nonisolated static let didEnterBackgroundNotification = NSApplication.didHideNotification
    /// Posted by `startMemoryPressureMonitor()` when the system reports memory pressure.
    nonisolated static let didReceiveMemoryWarningNotification = Notification.Name("HoshiDidReceiveMemoryWarning")

    private static var memoryPressureSource: DispatchSourceMemoryPressure?

    static func startMemoryPressureMonitor() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            NotificationCenter.default.post(name: didReceiveMemoryWarningNotification, object: nil)
        }
        source.resume()
        memoryPressureSource = source
    }
    #else
    nonisolated static let didBecomeActiveNotification = UIApplication.didBecomeActiveNotification
    nonisolated static let willResignActiveNotification = UIApplication.willResignActiveNotification
    nonisolated static let didEnterBackgroundNotification = UIApplication.didEnterBackgroundNotification
    nonisolated static let didReceiveMemoryWarningNotification = UIApplication.didReceiveMemoryWarningNotification
    #endif
}
