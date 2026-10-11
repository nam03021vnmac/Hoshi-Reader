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
    /// pages the user re-ran OCR on, they keep the OCR layer even when the embedded text is usable
    var ocrPages: Set<Int> = []

    init(pageCount: Int) {
        self.pageCount = pageCount
        self.pageSources = Array(repeating: .unknown, count: pageCount)
        self.pageCharacterCounts = Array(repeating: nil, count: pageCount)
    }

    private enum CodingKeys: String, CodingKey {
        case pageCount
        case pageSources
        case pageCharacterCounts
        case forceOCR
        case ocrPages
    }

    // fields added later are optional, so older files still load
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        pageSources = try container.decode([PDFTextSource].self, forKey: .pageSources)
        pageCharacterCounts = try container.decode([Int?].self, forKey: .pageCharacterCounts)
        forceOCR = try container.decodeIfPresent(Bool.self, forKey: .forceOCR) ?? false
        ocrPages = try container.decodeIfPresent(Set<Int>.self, forKey: .ocrPages) ?? []
    }
}
