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

    /// Top and bottom space the readers keep clear. iPad and Mac use fixed values. On iPhone they follow the
    /// window, and the top never drops below 20 so landscape (no status bar, top inset 0) isn't flush to the edge.
    static var readerSafeArea: (top: CGFloat, bottom: CGFloat) {
        if isLargeDevice {
            return (35, 20)
        }
        return (max(topSafeArea, 20), bottomSafeArea)
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

    // MARK: - Animation

    /// Animates view property changes, such as fading a web view in with `alpha`.
    static func animate(withDuration duration: TimeInterval, _ animations: @escaping () -> Void) {
        #if os(macOS)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            animations()
        }
        #else
        UIView.animate(withDuration: duration, animations: animations)
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
        // UIKit calls the expiration handler on the main thread
        var handler: (@Sendable () -> Void)?
        if let expirationHandler {
            handler = { @Sendable in
                MainActor.assumeIsolated { expirationHandler() }
            }
        }
        return BackgroundTaskID(identifier: UIApplication.shared.beginBackgroundTask(expirationHandler: handler))
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

    // MARK: - Screen

    /// Pixels per point where `view` is shown (on macOS), or on the main screen.
    static func displayScale(of view: PlatformView?) -> CGFloat {
        #if os(macOS)
        view?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        #else
        UIScreen.main.scale
        #endif
    }

    /// The main screen's size in points.
    static var screenSize: CGSize {
        #if os(macOS)
        NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        #else
        UIScreen.main.bounds.size
        #endif
    }

    /// The longest side in pixels of the largest screen. A Mac can move a window to any of its screens.
    static var screenPixelLongSide: CGFloat {
        #if os(macOS)
        NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 2880
        #else
        let size = UIScreen.main.nativeBounds.size
        return max(size.width, size.height)
        #endif
    }

    // MARK: - App lifecycle notifications

    #if os(macOS)
    nonisolated static let didBecomeActiveNotification = NSApplication.didBecomeActiveNotification
    nonisolated static let willResignActiveNotification = NSApplication.willResignActiveNotification
    nonisolated static let didEnterBackgroundNotification = NSApplication.didHideNotification
    nonisolated static let willEnterForegroundNotification = NSApplication.didUnhideNotification
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
    nonisolated static let willEnterForegroundNotification = UIApplication.willEnterForegroundNotification
    nonisolated static let didReceiveMemoryWarningNotification = UIApplication.didReceiveMemoryWarningNotification
    #endif
}
