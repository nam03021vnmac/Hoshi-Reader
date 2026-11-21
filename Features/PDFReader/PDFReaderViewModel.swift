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

private nonisolated struct ImageBox: @unchecked Sendable {
    let image: CGImage?
    
    init(_ image: CGImage?) {
        self.image = image
    }
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
    var upscaleImages: Bool
    /// (done, total) while the whole book is being recognized
    var bookOCRProgress: (done: Int, total: Int)?
    var ocrError: String?
    var coverNotice: PDFCoverNotice?
    var isChoosingCover = false
    var showTextBoxes = false {
        didSet { updateTextBoxes() }
    }
    /// the visible page is being upscaled
    var isUpscalingPage = false
    
    let maxSelectionLength = 16
    
    // stats
    var isTracking = false
    var isPaused = false
    private(set) var currentSession = ReadingSession.starting(at: .now)
    private var history: [String: Timestamped<ReadingSession?>] = [:]
    private var historyDays: [Date: ReadingTotal] = [:]
    private var historyTotal = ReadingTotal(date: .distantPast)
    @ObservationIgnored private var sessionId = UUID().uuidString
    private let statisticsResetTime: Int
    @ObservationIgnored private var lastTimestamp: Date = .now
    // characters of pages turned past since the last update
    @ObservationIgnored private var pendingCharacters = 0
    @ObservationIgnored private var jumpTarget: Int?
    
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored var highlightProvider: PDFHighlightOverlayProvider? {
        didSet {
            reloadUpscaledImages()
            refreshUpscaling()
        }
    }
    @ObservationIgnored private var textLayers: PDFTextLayerProvider?
    @ObservationIgnored private var currentScan: (pageIndex: Int, first: PDFGlyphRef)?
    @ObservationIgnored private var latestTapToken: UUID?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var bookOCRTask: Task<Void, Never>?
    @ObservationIgnored private var coverNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var ocrConfigurationKey: String?
    // the model prompt opens by itself at most once per reader session
    @ObservationIgnored private var ocrPromptShown = false
    @ObservationIgnored private var upscaler: PageUpscaleProvider?
    @ObservationIgnored private var upscaledURLs: [Int: URL] = [:]
    // at most one page holds its full resolution image, while it's zoomed
    @ObservationIgnored private var fullImagePage: Int?
    
    var pageCount: Int {
        info?.pageCount ?? 0
    }
    
    var coverURL: URL? {
        book.coverURL
    }
    
    init(book: BookMetadata) {
        self.book = book
        self.statisticsResetTime = UserConfig.shared.statisticsResetTime
        
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
            self.upscaleImages = false
            return
        }
        
        var info = BookStorage.loadPDFInfo(root: root)
        if info?.pageCount != document.pageCount {
            let previous = info
            info = PDFInfo(pageCount: document.pageCount)
            info?.isManga = previous?.isManga ?? false
            info?.upscaleImages = previous?.upscaleImages ?? false
            try? BookStorage.save(info, inside: root, as: FileNames.pdfInfo)
        }
        
        let saved = BookStorage.loadBookmark(root: root)?.chapterIndex ?? 0
        self.rootURL = root
        self.document = document
        self.info = info
        self.pageIndex = min(max(saved, 0), document.pageCount - 1)
        self.forceOCR = info?.forceOCR ?? false
        self.isManga = info?.isManga ?? false
        self.upscaleImages = info?.upscaleImages ?? false
        
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
        setUpscalerBookOCRRunning(true)
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
            setUpscalerBookOCRRunning(false)
        }
    }
    
    func cancelBookOCR() {
        bookOCRTask?.cancel()
    }
    
    func handleMemoryWarning() {
        highlightProvider?.clearImages(keeping: pageIndex)
        fullImagePage = nil
        if let upscaler {
            Task { await upscaler.handleMemoryWarning() }
        }
        guard let textLayers else {
            return
        }
        Task { await textLayers.clearMemoryCache() }
    }
    
    func close() {
        bookOCRTask?.cancel()
        stopUpscaling()
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
        if let upscaler {
            restoreFittedImage(leaving: index)
            let radius = UserConfig.shared.pdfPrefetchPages
            Task { await upscaler.focus(page: index, radius: radius, forward: forward) }
        }
    }
    
    func viewportChanged() {
        closePopups()
        loadFullImageIfZoomed()
    }
    
    // MARK: upscaling
    
    func setUpscaleImages(_ value: Bool) {
        upscaleImages = value
        if let textLayers {
            Task { await textLayers.setUpscaleImages(value) }
        }
        refreshUpscaling()
    }
    
    /// Starts from the view rather than init: SwiftUI can create view models it throws away, and those would keep working.
    private func refreshUpscaling() {
        guard upscaleImages else {
            stopUpscaling()
            return
        }
        guard upscaler == nil, let pdf = book.pdf, let rootURL else {
            return
        }
        let provider = PageUpscaleProvider(
            pdfURL: rootURL.appendingPathComponent(pdf),
            bookFolder: book.folder,
            pageCount: pageCount,
            screenLongSide: Self.screenLongSide,
            onImage: { [weak self] page, url in
                self?.showUpscaledImage(page: page, url: url)
            },
            onBusy: { [weak self] busy in
                self?.isUpscalingPage = busy
            }
        )
        upscaler = provider
        let page = pageIndex
        let radius = UserConfig.shared.pdfPrefetchPages
        let bookOCRRunning = bookOCRTask != nil
        Task {
            await provider?.setBookOCRRunning(bookOCRRunning)
            await provider?.focus(page: page, radius: radius)
        }
    }
    
    func setUpscalingPaused(_ paused: Bool) {
        guard let upscaler else {
            return
        }
        Task { await upscaler.setPaused(paused) }
    }
    
    private func stopUpscaling() {
        isUpscalingPage = false
        upscaledURLs.removeAll()
        fullImagePage = nil
        highlightProvider?.clearImages()
        guard let upscaler else {
            return
        }
        self.upscaler = nil
        Task { await upscaler.stop() }
    }
    
    private func setUpscalerBookOCRRunning(_ running: Bool) {
        guard let upscaler else {
            return
        }
        Task { await upscaler.setBookOCRRunning(running) }
    }
    
    private func showUpscaledImage(page: Int, url: URL) {
        guard upscaler != nil else {
            return
        }
        upscaledURLs[page] = url
        guard highlightProvider?.hasImage(pageIndex: page) == false else {
            return
        }
        loadImage(page: page, url: url, maxLongSide: fittedLongSide(page: page))
    }
    
    /// A new overlay provider comes with a rebuilt PDFKitView, and starts out empty
    private func reloadUpscaledImages() {
        fullImagePage = nil
        for (page, url) in upscaledURLs where Swift.abs(page - pageIndex) <= 1 {
            loadImage(page: page, url: url, maxLongSide: fittedLongSide(page: page))
        }
    }
    
    private func loadImage(page: Int, url: URL, maxLongSide: Int?) {
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                ImageBox(UpscaleCodec.decode(url, maxLongSide: maxLongSide))
            }.value.image
            guard let image, upscaler != nil else {
                return
            }
            highlightProvider?.setImage(image, pageIndex: page)
        }
    }
    
    private func loadFullImageIfZoomed() {
        guard upscaler != nil, fullImagePage != pageIndex, let pdfView, let url = upscaledURLs[pageIndex],
              let fit = fitScale(page: pageIndex), pdfView.scaleFactor > fit * Self.zoomedScale else {
            return
        }
        fullImagePage = pageIndex
        loadImage(page: pageIndex, url: url, maxLongSide: nil)
    }
    
    /// Swaps the page left behind back to the fitted image
    private func restoreFittedImage(leaving index: Int) {
        guard let page = fullImagePage, page != index else {
            return
        }
        fullImagePage = nil
        highlightProvider?.removeImage(pageIndex: page)
        if let url = upscaledURLs[page], Swift.abs(page - index) <= 1 {
            loadImage(page: page, url: url, maxLongSide: fittedLongSide(page: page))
        }
    }
    
    /// The scale that fits `page` on screen, which is the view's width in continuous mode
    private func fitScale(page: Int) -> CGFloat? {
        guard let bounds = document?.page(at: page).map(Self.displayedSize), bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        let view = viewSize
        if UserConfig.shared.pdfDisplayMode == .continuous {
            return view.width / bounds.width
        }
        return min(view.width / bounds.width, view.height / bounds.height)
    }
    
    /// The long side in pixels of `page` when fitted on screen, nil if that can't be told yet
    private func fittedLongSide(page: Int) -> Int? {
        guard let fit = fitScale(page: page), let size = document?.page(at: page).map(Self.displayedSize) else {
            return nil
        }
        return Int((max(size.width, size.height) * fit * Platform.displayScale(of: pdfView)).rounded(.up))
    }
    
    private var viewSize: CGSize {
        if let size = pdfView?.bounds.size, size.width > 0, size.height > 0 {
            return size
        }
        return Platform.screenSize
    }
    
    private static func displayedSize(of page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }
    
    private static var screenLongSide: CGFloat {
        Platform.screenPixelLongSide
    }
    
    private static let zoomedScale: CGFloat = 1.2
    
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

    /// Saves the part of the page under `box` (over the PDF view, origin at the top left) as the book's cover,
    /// e.g. the front of a dust jacket scanned as one wide page
    func setCover(from box: CGRect) {
        isChoosingCover = false
        guard let pdfView, let document, let rootURL, let pdf = book.pdf else {
            showCoverNotice(.failed)
            return
        }
        let box = pdfView.viewRect(fromTopLeft: box)
        guard let page = pdfView.page(for: CGPoint(x: box.midX, y: box.midY), nearest: true) else {
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
        if !currentSession.hasActivity {
            currentSession = .starting(at: .now)
        }
        isTracking = true
        resetTrackingBaseline()
    }
    
    func stopTracking() {
        guard isTracking else { return }
        flushStats()
        isTracking = false
    }
    
    var todaysTotal: ReadingTotal {
        let today = StatisticsDay.date(.now, resetTime: statisticsResetTime)
        var total = historyDays[today] ?? ReadingTotal(date: today)
        if StatisticsDay.date(Date(milliseconds: currentSession.startedAt), resetTime: statisticsResetTime) == today {
            total.add(currentSession)
        }
        return total
    }
    
    var allTimeTotal: ReadingTotal {
        var total = historyTotal
        total.add(currentSession)
        return total
    }
    
    // https://github.com/ttu-ttu/ebook-reader/blob/2703b50ec52b2e4f70afcab725c0f47dd8a66bf4/apps/web/src/lib/components/book-reader/book-reading-tracker/book-reading-tracker.svelte#L72
    func updateStats() {
        let now: Date = .now
        let timeDiff = now.timeIntervalSince(lastTimestamp)
        // never take back more than this session added, same as the EPUB reader
        let characterDiff = max(pendingCharacters, -currentSession.charactersRead)
        guard timeDiff > 0 else {
            return
        }
        
        currentSession.track(characters: characterDiff, time: timeDiff, until: now)
        
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
    
    private func saveStats() {
        var sessions = StatisticsStorage.load(folder: book.folder)
        applySessions(sessions)
        if currentSession.hasActivity && sessions[sessionId]?.value != currentSession {
            sessions[sessionId] = Timestamped(modified: Date.now.milliseconds, value: currentSession)
            StatisticsStorage.save(sessions, folder: book.folder)
        }
    }
    
    private func loadStatistics() {
        applySessions(StatisticsStorage.load(folder: book.folder))
    }
    
    private func applySessions(_ sessions: [String: Timestamped<ReadingSession?>]) {
        // the session was deleted elsewhere (statistics editor), so start a new one
        if let change = sessions[sessionId], change.value == nil {
            sessionId = UUID().uuidString
            currentSession = .starting(at: .now)
        }
        guard history != sessions else { return }
        history = sessions
        let days = StatisticsDay.grouped(history.filter { $0.key != sessionId }, resetTime: statisticsResetTime)
        historyDays = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0.total) })
        historyTotal = historyDays.values.reduce(into: ReadingTotal(date: .distantPast)) { $0.add($1) }
    }
}
