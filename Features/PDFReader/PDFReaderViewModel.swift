//
//  PDFReaderViewModel.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit
import SwiftUI
import CHoshiDicts
import Cxx
import CxxStdlib

enum PDFReaderSheet: Identifiable {
    case contents
    case settings
    
    var id: Self { self }
}

@Observable
@MainActor
final class PDFReaderViewModel {
    let book: BookMetadata
    let rootURL: URL?
    let document: PDFDocument?
    let info: PDFInfo?
    var pageIndex: Int
    var activeSheet: PDFReaderSheet?
    var popups: [PopupItem] = []
    var isLoadingPage = false
    
    let maxSelectionLength = 16
    
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored var highlightProvider: PDFHighlightOverlayProvider?
    @ObservationIgnored private var textLayers: PDFTextLayerProvider?
    @ObservationIgnored private var currentScan: (pageIndex: Int, first: PDFGlyphRef)?
    @ObservationIgnored private var latestTapToken: UUID?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    
    var pageCount: Int {
        info?.pageCount ?? 0
    }
    
    var coverURL: URL? {
        guard let rootURL, let cover = book.cover else {
            return nil
        }
        return rootURL.appendingPathComponent(cover)
    }
    
    init(book: BookMetadata) {
        self.book = book
        
        guard let pdf = book.pdf,
              let root = try? BookStorage.getBooksDirectory().appendingPathComponent(book.folder),
              let document = PDFDocument(url: root.appendingPathComponent(pdf)),
              document.pageCount > 0 else {
            self.rootURL = nil
            self.document = nil
            self.info = nil
            self.pageIndex = 0
            return
        }
        
        var info = BookStorage.loadPDFInfo(root: root)
        if info?.pageCount != document.pageCount {
            info = PDFInfo(pageCount: document.pageCount)
            try? BookStorage.save(info, inside: root, as: FileNames.pdfInfo)
        }
        
        let saved = BookStorage.loadBookmark(root: root)?.chapterIndex ?? 0
        self.rootURL = root
        self.document = document
        self.info = info
        self.pageIndex = min(max(saved, 0), document.pageCount - 1)
        
        if let info, let pdf = book.pdf {
            let provider = PDFTextLayerProvider(pdfURL: root.appendingPathComponent(pdf), bookRoot: root, info: info)
            self.textLayers = provider
            Task { await provider.prefetch(around: self.pageIndex, radius: UserConfig.shared.pdfPrefetchPages) }
        }
    }
    
    func pageChanged(to index: Int) {
        guard index != pageIndex else {
            return
        }
        let forward = index > pageIndex
        pageIndex = index
        latestTapToken = nil
        isLoadingPage = false
        clearSelection()
        closePopups()
        scheduleSave()
        if let textLayers {
            let radius = UserConfig.shared.pdfPrefetchPages
            Task { await textLayers.prefetch(around: index, radius: radius, forward: forward) }
        }
    }
    
    func viewportChanged() {
        closePopups()
    }
    
    func flushTextLayers() {
        guard let textLayers else {
            return
        }
        Task { await textLayers.flushInfo() }
    }
    
    // MARK: lookup
    
    /// Returns false if the tap didn't land on scannable text, so the caller treats it as a tap outside.
    func handlePageTap(pageIndex tappedPage: Int, point: CGPoint) async -> Bool {
        guard let textLayers else {
            return false
        }
        let token = UUID()
        latestTapToken = token
        
        var cached = await textLayers.cachedLayer(for: tappedPage)
        if cached == nil {
            isLoadingPage = true
            cached = try? await textLayers.layer(for: tappedPage)
            if latestTapToken == token {
                isLoadingPage = false
            }
        }
        // the user tapped elsewhere or turned the page meanwhile
        guard latestTapToken == token, let layer = cached else {
            return true
        }
        
        guard let hit = PDFTextScanner.hitTest(layer, point: point),
              currentScan?.pageIndex != tappedPage || currentScan?.first != hit,
              let result = PDFTextScanner.scan(layer, from: hit, maxLength: maxSelectionLength, scanNonJapaneseText: UserConfig.shared.scanNonJapaneseText),
              let pdfPage = document?.page(at: tappedPage),
              let pdfView else {
            clearSelection()
            return false
        }
        
        closePopups()
        let rect = pdfView.convert(result.firstGlyphRect, from: pdfPage)
        let selection = SelectionData(text: result.text, sentence: result.sentence, rect: rect, normalizedOffset: nil, clozeOffset: result.clozeOffset)
        let config = UserConfig.shared
        if let matched = handleTextSelection(selection, maxResults: config.maxResults, scanLength: config.scanLength, isVertical: result.isVertical, isFullWidth: config.popupFullWidth) {
            highlight(layer: layer, glyphs: Array(result.glyphs.prefix(matched)), pageIndex: tappedPage)
            currentScan = (tappedPage, hit)
        } else {
            clearSelection()
        }
        return true
    }
    
    private func highlight(layer: PDFTextLayer, glyphs: [PDFGlyphRef], pageIndex: Int) {
        var rects: [CGRect] = []
        var currentLine: Int?
        for ref in glyphs {
            let rect = layer.lines[ref.line].glyphs[ref.glyph].rect
            if currentLine == ref.line, let last = rects.popLast() {
                rects.append(last.union(rect))
            } else {
                rects.append(rect)
            }
            currentLine = ref.line
        }
        highlightProvider?.setHighlight(pageIndex: pageIndex, rects: rects)
    }
    
    func clearSelection() {
        currentScan = nil
        highlightProvider?.clear()
    }
    
    // todo: share with ReaderViewModel
    func handleTextSelection(_ selection: SelectionData, maxResults: Int, scanLength: Int, isVertical: Bool, isFullWidth: Bool) -> Int? {
        let lookupResults = LookupEngine.shared.lookup(selection.text, maxResults: maxResults, scanLength: scanLength)
        var dictionaryStyles: [String: String] = [:]
        for style in LookupEngine.shared.getStyles() {
            let name = String(decoding: style.dict_name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let css = String(decoding: style.styles.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            dictionaryStyles[name] = css
        }
        let popup = PopupItem(
            showPopup: false,
            currentSelection: selection,
            lookupResults: lookupResults,
            dictionaryStyles: dictionaryStyles,
            isVertical: isVertical,
            isFullWidth: isFullWidth,
            clearSelection: false,
            sasayakiCue: nil
        )
        popups.append(popup)
        
        if let firstResult = lookupResults.first {
            withAnimation(.default.speed(2.2)) {
                popups = popups.map {
                    var p = $0
                    if p.id == popup.id {
                        p.showPopup = true
                    }
                    return p
                }
            }
            let matched = String(decoding: firstResult.matched.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return matched.count
        }
        return nil
    }
    
    func closePopups() {
        guard !popups.isEmpty else { return }
        let popupIds = Set(popups.map(\.id))
        withAnimation(.default.speed(2.4)) {
            popups = popups.map {
                var p = $0
                p.showPopup = false
                return p
            }
        } completion: {
            self.popups.removeAll { popupIds.contains($0.id) }
        }
    }
    
    func closeChildPopups(parent: Int) {
        let popupIds = Set(popups.dropFirst(parent + 1).map(\.id))
        guard !popupIds.isEmpty else { return }
        withAnimation(.default.speed(2.4)) {
            popups = popups.map {
                var p = $0
                if popupIds.contains(p.id) {
                    p.showPopup = false
                }
                return p
            }
        } completion: {
            self.popups.removeAll { popupIds.contains($0.id) }
        }
    }
    
    func jump(to index: Int) {
        guard let document, let page = document.page(at: min(max(index, 0), pageCount - 1)) else {
            return
        }
        pdfView?.go(to: page)
    }
    
    func saveBookmark() {
        saveTask?.cancel()
        saveTask = nil
        guard let rootURL else {
            return
        }
        let bookmark = Bookmark(
            chapterIndex: pageIndex,
            progress: 0,
            characterCount: pageIndex + 1,
            lastModified: Date()
        )
        try? BookStorage.save(bookmark, inside: rootURL, as: FileNames.bookmark)
    }
    
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else {
                return
            }
            self?.saveBookmark()
        }
    }
}
