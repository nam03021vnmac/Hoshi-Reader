//
//  PlatformTypes.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

#if os(macOS)
import AppKit

typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#else
import UIKit

typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension Color {
    init(platformColor: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: platformColor)
        #else
        self.init(uiColor: platformColor)
        #endif
    }
}

#if os(macOS)
extension NSImage {
    nonisolated convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }

    nonisolated func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#endif
