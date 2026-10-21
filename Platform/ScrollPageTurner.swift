//
//  ScrollPageTurner.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import AppKit

/// Turns scroll wheel and trackpad events into page turns: one per trackpad swipe, and
/// one per burst of mouse wheel events.
@MainActor
final class ScrollPageTurner {
    /// How far a trackpad swipe moves before it turns the page.
    private let swipeThreshold: CGFloat = 30
    /// With smooth scrolling, a single wheel click arrives as a stream of small deltas,
    /// so a burst ends after a pause, or after `wheelRepeatInterval` while the wheel keeps spinning.
    private let wheelPause: TimeInterval = 0.15
    private let wheelRepeatInterval: TimeInterval = 0.5
    private var swipeDelta: CGSize = .zero
    private var swipeHandled = false
    private var lastWheelEvent: TimeInterval = 0
    private var lastWheelTurn: TimeInterval = 0
    private var wheelBurstTurned = false

    /// Returns the scroll delta that turns the page with this event, or nil while the
    /// gesture hasn't turned one (or already has). The delta follows the content, so a
    /// leftward swipe has a negative width and scrolling down a negative height.
    func pageTurnDelta(for event: NSEvent) -> CGSize? {
        // the momentum after a swipe never turns another page
        guard event.momentumPhase.isEmpty else {
            return nil
        }

        if event.phase.isEmpty {
            // a mouse wheel
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastWheelEvent > wheelPause {
                wheelBurstTurned = false
            }
            lastWheelEvent = now
            let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            guard !wheelBurstTurned || now - lastWheelTurn > wheelRepeatInterval, delta != .zero else {
                return nil
            }
            wheelBurstTurned = true
            lastWheelTurn = now
            return delta
        }

        if event.phase.contains(.began) {
            swipeDelta = .zero
            swipeHandled = false
        }
        swipeDelta.width += event.scrollingDeltaX
        swipeDelta.height += event.scrollingDeltaY
        guard !swipeHandled, max(abs(swipeDelta.width), abs(swipeDelta.height)) >= swipeThreshold else {
            return nil
        }
        swipeHandled = true
        return swipeDelta
    }
}
#endif
