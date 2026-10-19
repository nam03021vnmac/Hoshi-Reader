//
//  NotYetOnMacView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI

/// Stands in for a view whose macOS version hasn't been built yet.
/// Delete this once nothing references it.
struct NotYetOnMacView: View {
    let feature: String

    init(_ feature: String) {
        self.feature = feature
    }

    var body: some View {
        ContentUnavailableView(
            "\(feature) isn't available on Mac yet",
            systemImage: "macwindow.badge.plus"
        )
    }
}
#endif
