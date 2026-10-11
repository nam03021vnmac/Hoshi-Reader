//
//  PDFTextLayerProvider.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import os
import PDFKit

nonisolated struct PDFOCRConfiguration: Sendable {
    let mode: PDFOCRMode
    /// nil when the selected pack isn't installed
    let engine: (any OCREngine)?
    /// identifier of the selected pack, OCR layers from other engines are stale
    let engineIdentifier: String

    var key: String {
        "\(mode.rawValue)|\(engineIdentifier)|\(engine != nil)"
    }
}

actor PDFTextLayerProvider {
    private static let memoryLimit = 12

    private let document: PDFDocument?
    private let bookRoot: URL
    private var info: PDFInfo
    private var configuration: PDFOCRConfiguration

    private var cache: [Int: PDFTextLayer] = [:]
    private var recency: [Int] = []
    private var inFlight: [Int: Task<PDFTextLayer, Error>] = [:]
    // bumped whenever cached layers become invalid, so in-flight results from before are dropped
    private var generation = 0
    private var prefetchTask: Task<Void, Never>?
    private var infoDirty = false
    private var infoSaveTask: Task<Void, Never>?

    init(pdfURL: URL, bookRoot: URL, info: PDFInfo, configuration: PDFOCRConfiguration) {
        // own instance, the PDFView's document isn't safe to share across threads
        self.document = PDFDocument(url: pdfURL)
        self.bookRoot = bookRoot
        self.info = info
        self.configuration = configuration
    }

    func configure(_ configuration: PDFOCRConfiguration) {
        let changed = configuration.key != self.configuration.key
        self.configuration = configuration
        if changed {
            invalidateMemory()
        }
    }

    func setForceOCR(_ forceOCR: Bool) {
        guard info.forceOCR != forceOCR else {
            return
        }
        info.forceOCR = forceOCR
        infoDirty = true
        flushInfo()
        invalidateMemory()
    }

    func cachedLayer(for pageIndex: Int) -> PDFTextLayer? {
        guard let layer = cache[pageIndex] else {
            return nil
        }
        touch(pageIndex)
        return layer
    }

    /// Loads from memory or disk, or builds from embedded text / OCR.
    /// Throws OCRError.modelNotInstalled if the page needs OCR and no model is available.
    func layer(for pageIndex: Int, priority: TaskPriority = .userInitiated) async throws -> PDFTextLayer {
        if let cached = cachedLayer(for: pageIndex) {
            return cached
        }
        if let task = inFlight[pageIndex] {
            return try await task.value
        }
        let generation = generation
        let task = Task(priority: priority) {
            try await self.build(pageIndex: pageIndex, forceOCR: false)
        }
        inFlight[pageIndex] = task
        defer {
            if generation == self.generation {
                inFlight[pageIndex] = nil
            }
        }
        let layer = try await task.value
        if generation == self.generation {
            store(layer, pageIndex: pageIndex)
        }
        return layer
    }

    /// Discards the cached layer and runs OCR, even if the page has usable embedded text
    func rebuildWithOCR(pageIndex: Int) async throws -> PDFTextLayer {
        guard configuration.engine != nil else {
            throw OCRError.modelNotInstalled
        }
        try? FileManager.default.removeItem(at: BookStorage.textLayerURL(root: bookRoot, pageIndex: pageIndex))
        cache[pageIndex] = nil
        recency.removeAll { $0 == pageIndex }
        inFlight[pageIndex] = nil

        let generation = generation
        let layer = try await Task(priority: .userInitiated) {
            try await self.build(pageIndex: pageIndex, forceOCR: true)
        }.value
        if generation == self.generation {
            store(layer, pageIndex: pageIndex)
        }
        return layer
    }

    /// Warms current ± radius one page at a time, forward pages first.
    /// A new call replaces the previous window.
    func prefetch(around pageIndex: Int, radius: Int, forward: Bool = true) {
        prefetchTask?.cancel()
        prefetchTask = nil
        guard radius > 0 else {
            return
        }
        var wanted: [Int] = [pageIndex]
        for offset in 1...radius {
            wanted.append(pageIndex + (forward ? offset : -offset))
            wanted.append(pageIndex + (forward ? -offset : offset))
        }
        wanted = wanted.filter { $0 >= 0 && $0 < info.pageCount }

        prefetchTask = Task(priority: .utility) {
            for index in wanted {
                guard !Task.isCancelled else {
                    return
                }
                _ = try? await self.layer(for: index, priority: .utility)
            }
        }
    }

    /// Sequential whole-book OCR. Pages with a cached or embedded layer are skipped quickly.
    func ocrAllPages(progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        guard configuration.engine != nil else {
            throw OCRError.modelNotInstalled
        }
        let count = info.pageCount
        for index in 0..<count {
            try Task.checkCancellation()
            while ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                try await Task.sleep(for: .seconds(5))
            }
            _ = try await layer(for: index, priority: .utility)
            progress(index + 1, count)
        }
        flushInfo()
    }

    func cancelAll() {
        prefetchTask?.cancel()
        prefetchTask = nil
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        generation += 1
        flushInfo()
    }

    func clearMemoryCache() {
        cache.removeAll()
        recency.removeAll()
    }

    func flushInfo() {
        infoSaveTask?.cancel()
        infoSaveTask = nil
        guard infoDirty else {
            return
        }
        infoDirty = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(info) {
            try? data.write(to: bookRoot.appendingPathComponent(FileNames.pdfInfo), options: .atomic)
        }
    }

    private func invalidateMemory() {
        generation += 1
        inFlight.removeAll()
        prefetchTask?.cancel()
        prefetchTask = nil
        clearMemoryCache()
    }

    private func build(pageIndex: Int, forceOCR: Bool) async throws -> PDFTextLayer {
        guard let page = document?.page(at: pageIndex) else {
            return .empty(pageIndex: pageIndex)
        }
        let configuration = configuration
        let ignoreEmbedded = forceOCR || (configuration.mode != .off && (info.forceOCR || configuration.mode == .always))
        if !ignoreEmbedded,
           let layer = EmbeddedTextExtractor.extract(page: page, pageIndex: pageIndex),
           EmbeddedTextQuality.isUsable(layer, pageBounds: page.bounds(for: .cropBox)) {
            // extraction is cheap and deterministic, so it isn't written to disk
            record(.embedded, characterCount: layer.characterCount, pageIndex: pageIndex)
            return layer
        }
        if configuration.mode == .off && !forceOCR {
            return .empty(pageIndex: pageIndex)
        }

        if !forceOCR, let cached = loadFromDisk(pageIndex: pageIndex, configuration: configuration) {
            record(cached.source, characterCount: cached.characterCount, pageIndex: pageIndex)
            return cached
        }
        guard let engine = configuration.engine else {
            throw OCRError.modelNotInstalled
        }
        try Task.checkCancellation()

        #if DEBUG
        let clock = ContinuousClock()
        let start = clock.now
        #endif
        guard let rendered = PageRenderer.render(page, longSide: PageRenderer.ocrLongSide) else {
            throw OCRError.inference("could not render the page")
        }
        let lines = try await engine.recognize(rendered.image)
        let layer = OCRTextLayerBuilder.layer(from: lines, pixelToPage: rendered.pixelToPage, pageIndex: pageIndex, engine: engine.identifier)
        #if DEBUG
        OCRLog.logger.debug("page \(pageIndex + 1): \(layer.characterCount) characters in \((clock.now - start).milliseconds) ms")
        #endif

        saveToDisk(layer)
        record(layer.source, characterCount: layer.characterCount, pageIndex: pageIndex)
        return layer
    }

    private func loadFromDisk(pageIndex: Int, configuration: PDFOCRConfiguration) -> PDFTextLayer? {
        let url = BookStorage.textLayerURL(root: bookRoot, pageIndex: pageIndex)
        guard let data = try? Data(contentsOf: url),
              let layer = try? JSONDecoder().decode(PDFTextLayer.self, from: data) else {
            return nil
        }
        guard layer.version == PDFTextLayer.currentVersion, layer.pageIndex == pageIndex else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // a layer from another pack is re-OCR'd once the selected pack is installed, until then it's better than nothing
        if layer.engine != configuration.engineIdentifier && configuration.engine != nil {
            return nil
        }
        return layer
    }

    private func saveToDisk(_ layer: PDFTextLayer) {
        let url = BookStorage.textLayerURL(root: bookRoot, pageIndex: layer.pageIndex)
        guard let data = try? JSONEncoder().encode(layer) else {
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func record(_ source: PDFTextSource, characterCount: Int, pageIndex: Int) {
        guard info.pageSources.indices.contains(pageIndex), info.pageCharacterCounts.indices.contains(pageIndex) else {
            return
        }
        guard info.pageSources[pageIndex] != source || info.pageCharacterCounts[pageIndex] != characterCount else {
            return
        }
        info.pageSources[pageIndex] = source
        info.pageCharacterCounts[pageIndex] = characterCount
        infoDirty = true
        guard infoSaveTask == nil else {
            return
        }
        infoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else {
                return
            }
            await self?.flushInfo()
        }
    }

    private func store(_ layer: PDFTextLayer, pageIndex: Int) {
        cache[pageIndex] = layer
        touch(pageIndex)
        while recency.count > Self.memoryLimit, let oldest = recency.first {
            recency.removeFirst()
            cache[oldest] = nil
        }
    }

    private func touch(_ pageIndex: Int) {
        recency.removeAll { $0 == pageIndex }
        recency.append(pageIndex)
    }
}
