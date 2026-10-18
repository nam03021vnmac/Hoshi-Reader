//
//  ReaderDoubleTapTracker.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CoreGraphics

/// Tells single taps apart from double taps on the reader so a double tap
/// can seek Sasayaki audio. Only taps on text with a Sasayaki cue are held
/// back for the double-tap window, so the seek never flashes a lookup popup
/// first; every other tap runs right away.
@MainActor
final class ReaderDoubleTapTracker {
    enum Tap {
        case single(id: Int)
        case double
    }

    static let timeout: TimeInterval = 0.25
    static let slop: CGFloat = 36

    private var lastTap: (id: Int, time: TimeInterval, point: CGPoint)?
    private var nextID = 0
    private var pendingSingleTap: DispatchWorkItem?

    /// Records a tap the moment it lands. A `.single` tap must then be
    /// passed to `resolveSingleTap` once it is known whether to hold it back.
    func registerTap(at point: CGPoint) -> Tap {
        let now = ProcessInfo.processInfo.systemUptime
        cancelPendingSingleTap()
        if let lastTap,
           now - lastTap.time <= Self.timeout,
           abs(point.x - lastTap.point.x) <= Self.slop,
           abs(point.y - lastTap.point.y) <= Self.slop {
            self.lastTap = nil
            return .double
        }

        nextID += 1
        lastTap = (nextID, now, point)
        return .single(id: nextID)
    }

    /// Runs `action` now, or once the double-tap window passes when
    /// `deferred` is true. Drops it if a later tap already replaced or
    /// completed this one.
    func resolveSingleTap(id: Int, deferred: Bool, action: @escaping () -> Void) {
        guard let lastTap, lastTap.id == id else { return }
        guard deferred else {
            self.lastTap = nil
            action()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lastTap?.id == id else { return }
            self.lastTap = nil
            self.pendingSingleTap = nil
            action()
        }
        pendingSingleTap = work
        let remaining = max(0, Self.timeout - (ProcessInfo.processInfo.systemUptime - lastTap.time))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func cancelPendingSingleTap() {
        pendingSingleTap?.cancel()
        pendingSingleTap = nil
    }
}
