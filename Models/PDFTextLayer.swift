//
//  PDFTextLayer.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation

// All geometry is in PDF page space (points, bottom-left origin, same space as PDFPage.characterBounds)

nonisolated struct PDFGlyph: Codable, Sendable, Hashable {
    let character: String
    let rect: CGRect

    init(character: String, rect: CGRect) {
        self.character = character
        self.rect = rect
    }

    private enum CodingKeys: String, CodingKey {
        case character = "c"
        case rect = "r"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        character = try container.decode(String.self, forKey: .character)
        rect = try container.decode(CompactRect.self, forKey: .rect).rect
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(character, forKey: .character)
        try container.encode(CompactRect(rect), forKey: .rect)
    }
}

// [x, y, width, height] rounded to 0.1
nonisolated private struct CompactRect: Codable {
    let rect: CGRect

    init(_ rect: CGRect) {
        self.rect = rect
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(CGFloat.self)
        let y = try container.decode(CGFloat.self)
        let width = try container.decode(CGFloat.self)
        let height = try container.decode(CGFloat.self)
        rect = CGRect(x: x, y: y, width: width, height: height)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in [rect.origin.x, rect.origin.y, rect.width, rect.height] {
            try container.encode((value * 10).rounded() / 10)
        }
    }
}

nonisolated struct PDFTextLine: Codable, Sendable {
    let isVertical: Bool
    let isRuby: Bool
    let blockIndex: Int
    var glyphs: [PDFGlyph]
    var bounds: CGRect
    var text: String { glyphs.map(\.character).joined() }

    // cross-axis size
    var thickness: CGFloat {
        isVertical ? bounds.width : bounds.height
    }

    init(isVertical: Bool, isRuby: Bool = false, blockIndex: Int = 0, glyphs: [PDFGlyph]) {
        self.isVertical = isVertical
        self.isRuby = isRuby
        self.blockIndex = blockIndex
        self.glyphs = glyphs
        self.bounds = glyphs.dropFirst().reduce(glyphs.first?.rect ?? .zero) { $0.union($1.rect) }
    }

    private enum CodingKeys: String, CodingKey {
        case isVertical = "v"
        case isRuby = "r"
        case blockIndex = "b"
        case glyphs = "g"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isVertical: try container.decode(Bool.self, forKey: .isVertical),
            isRuby: try container.decode(Bool.self, forKey: .isRuby),
            blockIndex: try container.decode(Int.self, forKey: .blockIndex),
            glyphs: try container.decode([PDFGlyph].self, forKey: .glyphs)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isVertical, forKey: .isVertical)
        try container.encode(isRuby, forKey: .isRuby)
        try container.encode(blockIndex, forKey: .blockIndex)
        try container.encode(glyphs, forKey: .glyphs)
    }
}

nonisolated struct PDFTextLayer: Codable, Sendable {
    // bump to invalidate caches when the format or algorithm changes
    static let currentVersion = 1

    let version: Int
    let pageIndex: Int
    let source: PDFTextSource
    let engine: String
    var lines: [PDFTextLine]

    init(pageIndex: Int, source: PDFTextSource, engine: String, lines: [PDFTextLine]) {
        self.version = Self.currentVersion
        self.pageIndex = pageIndex
        self.source = source
        self.engine = engine
        self.lines = lines
    }

    static func empty(pageIndex: Int) -> PDFTextLayer {
        PDFTextLayer(pageIndex: pageIndex, source: .empty, engine: "none", lines: [])
    }

    var characterCount: Int {
        lines.reduce(0) { $0 + ($1.isRuby ? 0 : $1.glyphs.count) }
    }
}
