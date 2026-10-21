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
    case ocrModel
    case statistics
    
    var id: Self { self }
}

enum PDFCoverNotice {
    case saved
    case failed
}

@Observable
@MainActor
final class PDFReaderViewModel {
    private(set) var book: BookMetadata
    let rootURL: URL?
    let document: PDFDocument?
    let info: PDFInfo?
    var pageIndex: Int
    var activeSheet: PDFReaderSheet?
    var popups: [PopupItem] = []
    var isLoadingPage = false
    var forceOCR: Bool
    var isManga: Bool
    /// (done, total) while the whole book is being recognized
    var bookOCRProgress: (done: Int, total: Int)?
    var ocrError: String?
    var coverNotice: PDFCoverNotice?
    var isChoosingCover = false
    var showTextBoxes = false {
        didSet { updateTextBoxes() }
    }
    
    let maxSelectionLength = 16
    
    // stats
    var isTracking = false
    var isPaused = false
    var sessionStatistics: Statistics
    var todaysStatistics: Statistics
    var allTimeStatistics: Statistics
    private let statisticsResetTime: Int
    @ObservationIgnored private var stats: [Statistics] = []
    @ObservationIgnored private var lastTimestamp: Date = .now
    // characters of pages turned past since the last update
    @ObservationIgnored private var pendingCharacters = 0
    @ObservationIgnored private var jumpTarget: Int?
    
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored var highlightProvider: PDFHighlightOverlayProvider?
    @ObservationIgnored private var textLayers: PDFTextLayerProvider?
    @ObservationIgnored private var currentScan: (pageIndex: Int, first: PDFGlyphRef)?
    @ObservationIgnored private var latestTapToken: UUID?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var bookOCRTask: Task<Void, Never>?
    @ObservationIgnored private var coverNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var ocrConfigurationKey: String?
    // the model prompt opens by itself at most once per reader session
    @ObservationIgnored private var ocrPromptShown = false
    
    var pageCount: Int {
        info?.pageCount ?? 0
    }
    
    var coverURL: URL? {
        book.coverURL
    }
    
    init(book: BookMetadata) {
        self.book = book
        let resetTime = UserConfig.shared.statisticsResetTime
        self.statisticsResetTime = resetTime
        self.sessionStatistics = Self.getDefaultStatistic(title: book.title, resetTime: resetTime)
        self.todaysStatistics = Self.getDefaultStatistic(title: book.title, resetTime: resetTime)
        self.allTimeStatistics = Self.getDefaultStatistic(title: book.title, resetTime: resetTime)
        
        guard let pdf = book.pdf,
              let root = try? BookStorage.getBooksDirectory().appendingPathComponent(book.folder),
              let document = PDFDocument(url: root.appendingPathComponent(pdf)),
              document.pageCount > 0 else {
            self.rootURL = nil
            self.document = nil
            self.info = nil
            self.pageIndex = 0
            self.forceOCR = false
            self.isManga = false
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
        self.forceOCR = info?.forceOCR ?? false
        self.isManga = info?.isManga ?? false
        
        if let info, let pdf = book.pdf {
            let configuration = ocrConfiguration()
            ocrConfigurationKey = configuration.key
            let provider = PDFTextLayerProvider(pdfURL: root.appendingPathComponent(pdf), bookRoot: root, info: info, configuration: configuration)
            self.textLayers = provider
            Task { await provider.prefetch(around: self.pageIndex, radius: UserConfig.shared.pdfPrefetchPages) }
        }
        
        loadStatistics()
        if UserConfig.shared.statisticsAutostartMode == .on {
            startTracking()
        }
    }
    
    // MARK: OCR
    
    /// Manga books use the manga pack, everything else the standard one
    var ocrPack: OCRModelPack {
        isManga ? .v6Manga : .v6Small
    }
    
    private func ocrConfiguration() -> PDFOCRConfiguration {
        let config = UserConfig.shared
        let pack = ocrPack
        return PDFOCRConfiguration(
            mode: config.pdfOCRMode,
            engine: config.pdfOCRMode == .off ? nil : OCRModelStore.shared.engine(for: pack),
            engineIdentifier: OCRModelManifest.engineIdentifier(for: pack)
        )
    }
    
    var ocrEnabled: Bool {
        UserConfig.shared.pdfOCRMode != .off
    }
    
    var isOCRModelInstalled: Bool {
        OCRModelStore.shared.state(for: ocrPack) == .installed
    }
    
    /// Picks up changes to the OCR mode, the book's pack, or a finished model download
    func refreshOCR() {
        let configuration = ocrConfiguration()
        guard configuration.key != ocrConfigurationKey, let textLayers else {
            return
        }
        ocrConfigurationKey = configuration.key
        if configuration.engine != nil && activeSheet == .ocrModel {
            activeSheet = nil
        }
        let page = pageIndex
        let radius = UserConfig.shared.pdfPrefetchPages
        Task {
            await textLayers.configure(configuration)
            await textLayers.prefetch(around: page, radius: radius)
            updateTextBoxes()
        }
    }
    
    func setForceOCR(_ value: Bool) {
        forceOCR = value
        clearSelection()
        closePopups()
        guard let textLayers else {
            return
        }
        let page = pageIndex
        let radius = UserConfig.shared.pdfPrefetchPages
        Task {
            await textLayers.setForceOCR(value)
            await textLayers.prefetch(around: page, radius: radius)
            updateTextBoxes()
        }
        if value && !isOCRModelInstalled {
            activeSheet = .ocrModel
        }
    }
    
    func setManga(_ value: Bool) {
        isManga = value
        clearSelection()
        closePopups()
        if let textLayers {
            Task { await textLayers.setManga(value) }
        }
        // pages recognized with the other pack are recognized again as they're needed
        refreshOCR()
        if value && !isOCRModelInstalled {
            activeSheet = .ocrModel
        }
    }
    
    func rerunOCR() {
        guard let textLayers else {
            return
        }
        guard isOCRModelInstalled else {
            activeSheet = .ocrModel
            return
        }
        let page = pageIndex
        let token = UUID()
        latestTapToken = token
        clearSelection()
        closePopups()
        isLoadingPage = true
        Task {
            do {
                let layer = try await textLayers.rebuildWithOCR(pageIndex: page)
                if showTextBoxes {
                    highlightProvider?.setBoxes(PDFTextBoxes(layer: layer), pageIndex: page)
                }
            } catch is CancellationError {
            } catch {
                ocrError = error.localizedDescription
            }
            if latestTapToken == token {
                isLoadingPage = false
            }
        }
    }
    
    func startBookOCR() {
        guard let textLayers, bookOCRTask == nil else {
            return
        }
        guard isOCRModelInstalled else {
            activeSheet = .ocrModel
            return
        }
        bookOCRProgress = (0, pageCount)
        bookOCRTask = Task {
            do {
                try await textLayers.ocrAllPages { [self] done, total in
                    Task { @MainActor in
                        guard let progress = self.bookOCRProgress, done > progress.done else {
                            return
                        }
                        self.bookOCRProgress = (done, total)
                    }
                }
            } catch is CancellationError {
            } catch {
                ocrError = error.localizedDescription
            }
            bookOCRTask = nil
            bookOCRProgress = nil
        }
    }
    
    func cancelBookOCR() {
        bookOCRTask?.cancel()
    }
    
    func handleMemoryWarning() {
        guard let textLayers else {
            return
        }
        Task { await textLayers.clearMemoryCache() }
    }
    
    func close() {
        bookOCRTask?.cancel()
        guard let textLayers else {
            OCRModelStore.shared.releaseEngineSessions()
            return
        }
        Task {
            await textLayers.cancelAll()
            // the models take tens to hundreds of MB, they reload on the next OCR request
            OCRModelStore.shared.releaseEngineSessions()
        }
    }
    
    private func updateTextBoxes() {
        guard showTextBoxes else {
            highlightProvider?.clearBoxes()
            return
        }
        guard let textLayers else {
            return
        }
        let page = pageIndex
        Task {
            guard let layer = try? await textLayers.layer(for: page), showTextBoxes else {
                return
            }
            highlightProvider?.setBoxes(PDFTextBoxes(layer: layer), pageIndex: page)
        }
    }
    
    func pageChanged(to index: Int) {
        guard index != pageIndex else {
            return
        }
        let forward = index > pageIndex
        let previous = pageIndex
        let jumped = jumpTarget == index
        jumpTarget = nil
        pageIndex = index
        latestTapToken = nil
        isLoadingPage = false
        clearSelection()
        closePopups()
        scheduleSave()
        if !isTracking && !jumped && UserConfig.shared.statisticsAutostartMode == .pageturn {
            startTracking()
        } else if !jumped && abs(index - previous) <= 5 {
            // continuous scrolling can skip a page notification or two.
            // moving back subtracts, like the EPUB reader, so paging back and forth doesn't add up
            if forward {
                countPages(previous..<index, sign: 1)
            } else {
                countPages(index..<previous, sign: -1)
            }
        }
        if let textLayers {
            let radius = UserConfig.shared.pdfPrefetchPages
            Task { await textLayers.prefetch(around: index, radius: radius, forward: forward) }
        }
        updateTextBoxes()
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
        isLoadingPage = false
        
        var cached = await textLayers.cachedLayer(for: tappedPage)
        if cached == nil {
            // disk cache hits are fast, only show the indicator once it's clearly OCR
            let indicator = Task {
                try await Task.sleep(for: .milliseconds(150))
                if latestTapToken == token {
                    isLoadingPage = true
                }
            }
            do {
                cached = try await textLayers.layer(for: tappedPage)
            } catch OCRError.modelNotInstalled {
                if latestTapToken == token && !ocrPromptShown && activeSheet == nil {
                    ocrPromptShown = true
                    activeSheet = .ocrModel
                    indicator.cancel()
                    isLoadingPage = false
                    return true
                }
            } catch is CancellationError {
            } catch {
                if latestTapToken == token {
                    ocrError = error.localizedDescription
                }
            }
            indicator.cancel()
            if latestTapToken == token {
                isLoadingPage = false
            }
        }
        // the user tapped elsewhere or turned the page meanwhile
        guard latestTapToken == token else {
            return true
        }
        guard let layer = cached else {
            clearSelection()
            return false
        }
        if showTextBoxes {
            highlightProvider?.setBoxes(PDFTextBoxes(layer: layer), pageIndex: tappedPage)
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
        let rect = pdfView.topLeftRect(for: result.firstGlyphRect, from: pdfPage)
        let selection = SelectionData(text: result.text, sentence: result.sentence, rect: rect, normalizedOffset: nil, clozeOffset: result.clozeOffset)
        let config = UserConfig.shared
        guard let matched = handleTextSelection(selection, maxResults: config.maxResults, scanLength: config.scanLength, isVertical: result.isVertical, isFullWidth: config.popupFullWidth) else {
            // no dictionary match, so the tap toggles the controls like a tap on blank space
            clearSelection()
            return false
        }
        highlight(layer: layer, glyphs: Array(result.glyphs.prefix(matched)), pageIndex: tappedPage)
        currentScan = (tappedPage, hit)
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
        // a popup that never shows would make the next tap close it instead of toggling the controls
        guard !lookupResults.isEmpty else {
            return nil
        }
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
    
    // MARK: cover

    func beginChoosingCover() {
        clearSelection()
        closePopups()
        isChoosingCover = true
    }

    /// Saves the part of the page under `box` (in the PDF view's coordinates) as the book's cover,
    /// e.g. the front of a dust jacket scanned as one wide page
    func setCover(from box: CGRect) {
        isChoosingCover = false
        guard let pdfView, let document, let rootURL, let pdf = book.pdf,
              let page = pdfView.page(for: CGPoint(x: box.midX, y: box.midY), nearest: true) else {
            showCoverNotice(.failed)
            return
        }
        // fitted in view space so the cover keeps the shelf's shape on rotated pages too
        let pageRect = pdfView.convert(page.bounds(for: .cropBox), from: page)
        guard pageRect.width >= 1, pageRect.height >= 1 else {
            showCoverNotice(.failed)
            return
        }
        let region = pdfView.convert(Self.fit(box, in: pageRect), to: page)
        let pageIndex = document.index(for: page)
        let pdfURL = rootURL.appendingPathComponent(pdf)
        let folder = book.folder
        // a new name each time, covers are cached by path
        let fileName = "cover-\(UUID().uuidString.prefix(8).lowercased()).jpg"

        Task {
            // its own document, the PDFView is drawing the shared one on the main thread
            let path = await Task.detached {
                guard let page = PDFDocument(url: pdfURL)?.page(at: pageIndex) else {
                    return nil as String?
                }
                return try? PDFImporter.writeCover(page, region: region, folder: folder, fileName: fileName)
            }.value

            var saved = false
            if let path {
                let oldCoverURL = book.coverURL
                var metadata = BookStorage.loadMetadata(root: rootURL) ?? book
                metadata.cover = path
                if (try? BookStorage.saveMetadata(metadata, inside: rootURL)) != nil {
                    book.cover = path
                    if let oldCoverURL, oldCoverURL.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL {
                        try? FileManager.default.removeItem(at: oldCoverURL)
                    }
                    saved = true
                } else {
                    try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(fileName))
                }
            }
            showCoverNotice(saved ? .saved : .failed)
        }
    }

    /// Moves `rect` onto the page, shrinking it to the same shape if it's bigger, so the cover has no blank edges
    private static func fit(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        let scale = min(1, bounds.width / rect.width, bounds.height / rect.height)
        var fitted = CGRect(x: 0, y: 0, width: rect.width * scale, height: rect.height * scale)
        fitted.origin.x = min(max(rect.midX - fitted.width / 2, bounds.minX), bounds.maxX - fitted.width)
        fitted.origin.y = min(max(rect.midY - fitted.height / 2, bounds.minY), bounds.maxY - fitted.height)
        return fitted
    }

    private func showCoverNotice(_ notice: PDFCoverNotice) {
        coverNoticeTask?.cancel()
        coverNotice = notice
        coverNoticeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else {
                return
            }
            coverNotice = nil
        }
    }

    func jump(to index: Int) {
        let target = min(max(index, 0), pageCount - 1)
        guard let document, let page = document.page(at: target) else {
            return
        }
        // jumps don't count as characters read
        jumpTarget = target
        flushStats()
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
        flushStats()
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
    
    // MARK: statistics
    // todo: share with ReaderViewModel
    
    func startTracking() {
        isTracking = true
        resetTrackingBaseline()
    }
    
    func stopTracking() {
        guard isTracking else { return }
        flushStats()
        isTracking = false
    }
    
    // https://github.com/ttu-ttu/ebook-reader/blob/2703b50ec52b2e4f70afcab725c0f47dd8a66bf4/apps/web/src/lib/components/book-reader/book-reading-tracker/book-reading-tracker.svelte#L72
    func updateStats() {
        let currentDateKey = Self.formattedDate(date: .now, resetTime: statisticsResetTime)
        if todaysStatistics.dateKey != currentDateKey {
            if let index = stats.firstIndex(where: { $0.dateKey == todaysStatistics.dateKey }) {
                stats[index] = todaysStatistics
            } else {
                stats.append(todaysStatistics)
            }
            todaysStatistics = stats.first(where: { $0.dateKey == currentDateKey }) ?? Self.getDefaultStatistic(title: book.title, resetTime: statisticsResetTime)
        }
        
        let now: Date = .now
        let timeDiff = now.timeIntervalSince(lastTimestamp)
        // never take back more than this session added, same as the EPUB reader
        let characterDiff = max(pendingCharacters, -sessionStatistics.charactersRead)
        let lastStatisticModified = Int(now.timeIntervalSince1970 * 1000)
        guard timeDiff > 0 else {
            return
        }
        
        updateStatistic(to: &sessionStatistics, timeDiff: timeDiff, characterDiff: characterDiff, lastStatisticModified: lastStatisticModified)
        updateStatistic(to: &todaysStatistics, timeDiff: timeDiff, characterDiff: characterDiff, lastStatisticModified: lastStatisticModified)
        updateStatistic(to: &allTimeStatistics, timeDiff: timeDiff, characterDiff: characterDiff, lastStatisticModified: lastStatisticModified)
        
        lastTimestamp = now
        pendingCharacters = 0
    }
    
    func resetTrackingBaseline() {
        lastTimestamp = .now
        pendingCharacters = 0
    }
    
    /// Adds (sign 1) or subtracts (sign -1) the characters of pages the user moved past. Pages whose text was never built count as 0.
    private func countPages(_ pages: Range<Int>, sign: Int) {
        guard isTracking, !isPaused, let textLayers else {
            return
        }
        Task {
            var count = 0
            for page in pages {
                count += await textLayers.characterCount(for: page) ?? 0
            }
            if isTracking && !isPaused {
                pendingCharacters += sign * count
            }
        }
    }
    
    private func flushStats() {
        guard isTracking, rootURL != nil else { return }
        if !isPaused {
            updateStats()
        }
        saveStats()
    }
    
    // https://github.com/ttu-ttu/ebook-reader/blob/2703b50ec52b2e4f70afcab725c0f47dd8a66bf4/apps/web/src/lib/components/book-reader/book-reading-tracker/book-reading-tracker.svelte#L722
    private func updateStatistic(to: inout Statistics, timeDiff: Double, characterDiff: Int, lastStatisticModified: Int) {
        to.readingTime += timeDiff
        to.charactersRead = max(to.charactersRead + characterDiff, 0)
        to.lastReadingSpeed = to.readingSpeed
        to.maxReadingSpeed = max(to.maxReadingSpeed, to.lastReadingSpeed)
        to.minReadingSpeed = to.minReadingSpeed != 0 ? min(to.minReadingSpeed, to.lastReadingSpeed) : to.lastReadingSpeed
        if characterDiff != 0 {
            to.altMinReadingSpeed = to.altMinReadingSpeed != 0 ? min(to.altMinReadingSpeed, to.lastReadingSpeed) : to.lastReadingSpeed
        }
        to.lastStatisticModified = lastStatisticModified
    }
    
    private func saveStats() {
        guard let rootURL else {
            return
        }
        if let index = stats.firstIndex(where: { $0.dateKey == todaysStatistics.dateKey }) {
            stats[index] = todaysStatistics
        } else {
            stats.append(todaysStatistics)
        }
        
        stats = Statistics.merged(stats).filter(\.hasActivity)
        try? BookStorage.save(stats, inside: rootURL, as: FileNames.statistics)
    }
    
    private func loadStatistics() {
        guard let rootURL else {
            return
        }
        stats = Statistics.merged(BookStorage.loadStatistics(root: rootURL) ?? [])
        todaysStatistics = stats.first(where: { $0.dateKey == Self.formattedDate(date: .now, resetTime: statisticsResetTime) }) ?? Self.getDefaultStatistic(title: book.title, resetTime: statisticsResetTime)
        allTimeStatistics = Self.getDefaultStatistic(title: book.title, resetTime: statisticsResetTime)
        
        let allTime = stats.reduce(into: ReadingDay(date: .now)) { $0.add($1) }
        allTimeStatistics.charactersRead = allTime.charactersRead
        allTimeStatistics.readingTime = allTime.readingTime
        allTimeStatistics.lastReadingSpeed = allTime.readingSpeed
    }
    
    private static func getDefaultStatistic(title: String, resetTime: Int = 0) -> Statistics {
        return Statistics(title: title, dateKey: Self.formattedDate(date: .now, resetTime: resetTime), charactersRead: 0, readingTime: 0, minReadingSpeed: 0, altMinReadingSpeed: 0, lastReadingSpeed: 0, maxReadingSpeed: 0, lastStatisticModified: 0)
    }
    
    private static func formattedDate(date: Date, resetTime: Int = 0) -> String {
        let adjustedDate = date.addingTimeInterval(-Double(resetTime) * 60)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: adjustedDate)
    }
}
