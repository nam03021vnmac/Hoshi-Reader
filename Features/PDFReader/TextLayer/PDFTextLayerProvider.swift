//
//  PDFTextLayerProvider.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit

actor PDFTextLayerProvider {
    private static let memoryLimit = 12

    private let document: PDFDocument?
    private let bookRoot: URL
    private var info: PDFInfo

    private var cache: [Int: PDFTextLayer] = [:]
    private var recency: [Int] = []
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]
    private var infoDirty = false
    private var infoSaveTask: Task<Void, Never>?

    init(pdfURL: URL, bookRoot: URL, info: PDFInfo) {
        // own instance, the PDFView's document isn't safe to share across threads
        self.document = PDFDocument(url: pdfURL)
        self.bookRoot = bookRoot
        self.info = info
    }

    func cachedLayer(for pageIndex: Int) -> PDFTextLayer? {
        guard let layer = cache[pageIndex] else {
            return nil
        }
        touch(pageIndex)
        return layer
    }

    func layer(for pageIndex: Int) async throws -> PDFTextLayer {
        if let cached = cachedLayer(for: pageIndex) {
            return cached
        }
        // extraction is synchronous, so the actor already coalesces concurrent requests for the same page
        let layer = build(pageIndex: pageIndex)
        store(layer, pageIndex: pageIndex)
        return layer
    }

    /// Warms current ± radius, forward pages first
    func prefetch(around pageIndex: Int, radius: Int, forward: Bool = true) {
        guard radius > 0 else {
            return
        }
        var wanted: [Int] = []
        for offset in 1...radius {
            wanted.append(pageIndex + (forward ? offset : -offset))
            wanted.append(pageIndex + (forward ? -offset : offset))
        }
        wanted = wanted.filter { $0 >= 0 && $0 < info.pageCount }

        let window = Set(wanted)
        for (index, task) in prefetchTasks where !window.contains(index) {
            task.cancel()
            prefetchTasks[index] = nil
        }
        for index in wanted where cache[index] == nil && prefetchTasks[index] == nil {
            prefetchTasks[index] = Task(priority: .utility) { [weak self] in
                guard !Task.isCancelled else {
                    return
                }
                _ = try? await self?.layer(for: index)
                await self?.prefetchFinished(index)
            }
        }
    }

    func cancelAll() {
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        flushInfo()
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

    private func prefetchFinished(_ pageIndex: Int) {
        prefetchTasks[pageIndex] = nil
    }

    private func build(pageIndex: Int) -> PDFTextLayer {
        guard let page = document?.page(at: pageIndex) else {
            return .empty(pageIndex: pageIndex)
        }
        if !info.forceOCR,
           let layer = EmbeddedTextExtractor.extract(page: page, pageIndex: pageIndex),
           EmbeddedTextQuality.isUsable(layer, pageBounds: page.bounds(for: .cropBox)) {
            record(.embedded, characterCount: layer.characterCount, pageIndex: pageIndex)
            return layer
        }
        // no OCR yet, so the page stays unclassified
        return .empty(pageIndex: pageIndex)
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
