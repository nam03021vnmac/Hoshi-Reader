//
//  PDFBook.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

nonisolated enum PDFTextSource: String, Codable, Sendable {
    case unknown
    case embedded
    case ocr
    case empty
}

nonisolated struct PDFInfo: Codable, Sendable {
    let pageCount: Int
    var pageSources: [PDFTextSource]
    var pageCharacterCounts: [Int?]
    var forceOCR: Bool = false
    
    init(pageCount: Int) {
        self.pageCount = pageCount
        self.pageSources = Array(repeating: .unknown, count: pageCount)
        self.pageCharacterCounts = Array(repeating: nil, count: pageCount)
    }
}
