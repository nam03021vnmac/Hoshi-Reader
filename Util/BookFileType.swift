//
//  BookFileType.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

nonisolated enum BookFileType {
    case epub
    case pdf
    
    static func detect(_ url: URL) -> BookFileType? {
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 1024), !head.isEmpty {
                // the spec allows junk before the header
                if head.range(of: Data("%PDF-".utf8)) != nil {
                    return .pdf
                }
                if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
                    return .epub
                }
            }
        }
        
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "epub": return .epub
        default: return nil
        }
    }
}
