//
//  PageUpscaleProvider.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Scheduling follows ImageEnhancer.kt from HaoweiLi97/mihon_img_upscale (Apache-2.0).
//

import Foundation
import os

/// Decides which page the worker gets next: the visible one first, then by distance, one at a time.
actor PageUpscaleProvider {
    /// Pages closer than this are left to finish, they'll be read soon anyway
    private static let nearbyPages = 2
    private static let settleDelay = Duration.milliseconds(250)
    /// Pages next to the visible one, decoded ahead so turning to them doesn't flash
    private static let prewarmRadius = 1
    private static let minMemoryForPreload = 400 * 1024 * 1024
    private static let minMemoryForVisible = 150 * 1024 * 1024

    private static let logger = Logger(subsystem: "HoshiReader", category: "Upscale")
    
    private let cache: UpscaleCache
    private let worker: UpscaleWorker
    private let pageCount: Int
    private let onImage: @MainActor @Sendable (Int, URL) -> Void
    private let onBusy: @MainActor @Sendable (Bool) -> Void

    private var visible = 0
    private var wanted: [Int] = []
    private var activePage: Int?
    private var activeTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var paused = false
    private var stopped = false
    private var bookOCRRunning = false
    private var reportedBusy = false
    private var preloadChecked = false
    private var preloadSupported = true

    init?(
        pdfURL: URL,
        bookFolder: String,
        pageCount: Int,
        screenLongSide: CGFloat,
        onImage: @escaping @MainActor @Sendable (Int, URL) -> Void,
        onBusy: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard let cache = UpscaleCache(bookFolder: bookFolder, pdfURL: pdfURL, tiler: .animeV3) else {
            return nil
        }
        self.cache = cache
        self.worker = UpscaleWorker(pdfURL: pdfURL, cache: cache, screenLongSide: screenLongSide)
        self.pageCount = pageCount
        self.onImage = onImage
        self.onBusy = onBusy
        Task.detached(priority: .background) {
            UpscaleCache.trim()
        }
    }

    /// A new call replaces the previous window
    func focus(page: Int, radius: Int, forward: Bool = true) {
        guard !stopped else {
            return
        }
        visible = page
        var pages = [page]
        for offset in stride(from: 1, through: max(radius, 0), by: 1) {
            pages.append(page + (forward ? offset : -offset))
            pages.append(page + (forward ? -offset : offset))
        }
        wanted = pages.filter { $0 >= 0 && $0 < pageCount }

        deliverCachedImages()
        preemptIfNeeded()
        reportBusy()

        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else {
                return
            }
            await startNext()
        }
    }

    func setBookOCRRunning(_ running: Bool) {
        bookOCRRunning = running
    }

    /// Pausing stops the page in progress, it starts over on resume
    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            settleTask?.cancel()
            activeTask?.cancel()
        } else {
            Task { await startNext() }
        }
    }

    func handleMemoryWarning() async {
        activeTask?.cancel()
        await worker.releaseModel()
    }

    func stop() async {
        stopped = true
        settleTask?.cancel()
        activeTask?.cancel()
        wanted = []
        await worker.releaseModel()
    }

    private func deliverCachedImages() {
        let pages = wanted.filter { Swift.abs($0 - visible) <= Self.prewarmRadius }
        for page in pages {
            guard let url = cache.imageURL(page: page) else {
                continue
            }
            cache.touch(url)
            let onImage = onImage
            Task { @MainActor in
                onImage(page, url)
            }
        }
    }

    private func needsWork(_ page: Int) -> Bool {
        cache.imageURL(page: page) == nil && !cache.isSkipped(page: page)
    }

    private func preemptIfNeeded() {
        guard let activePage, activePage != visible else {
            return
        }
        if !wanted.contains(activePage) {
            activeTask?.cancel()
        } else if needsWork(visible), Swift.abs(activePage - visible) > Self.nearbyPages {
            activeTask?.cancel()
        }
    }

    private var availableMemory: Int {
        #if os(iOS)
        // 0 means there's no limit to measure against, like in the simulator
        let available = os_proc_available_memory()
        return available == 0 ? Int.max : available
        #else
        Int.max
        #endif
    }

    private func preloadAllowed() -> Bool {
        preloadSupported
            && !bookOCRRunning
            && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
            && availableMemory >= Self.minMemoryForPreload
    }

    private func visibleAllowed() -> Bool {
        ProcessInfo.processInfo.thermalState != .critical && availableMemory >= Self.minMemoryForVisible
    }

    private func startNext() async {
        guard activeTask == nil, !paused, !stopped else {
            return
        }
        if !preloadChecked {
            preloadChecked = true
            preloadSupported = await worker.runsOnNeuralEngine()
            if !preloadSupported {
                Self.logger.info("model isn't on the Neural Engine, only upscaling the visible page")
            }
            guard activeTask == nil, !paused, !stopped else {
                return
            }
        }
        let queue: [Int]
        if !visibleAllowed() {
            queue = []
        } else if preloadAllowed() {
            queue = wanted
        } else {
            queue = wanted.first.map { [$0] } ?? []
        }
        guard let page = queue.first(where: needsWork) else {
            if queue.isEmpty {
                Self.logger.info("paused: thermal state or memory")
            }
            reportBusy()
            return
        }
        activePage = page
        let worker = worker
        activeTask = Task(priority: page == visible ? .userInitiated : .utility) {
            let outcome = try? await worker.process(pageIndex: page)
            await self.finished(page: page, outcome: outcome)
        }
        reportBusy()
    }

    private func finished(page: Int, outcome: UpscaleWorker.Outcome?) async {
        activePage = nil
        activeTask = nil
        if !stopped, case .image(let url)? = outcome, Swift.abs(page - visible) <= Self.prewarmRadius {
            let onImage = onImage
            await onImage(page, url)
        }
        reportBusy()
        await startNext()
    }

    private func reportBusy() {
        let busy = !stopped && !paused && activePage == visible
        guard busy != reportedBusy else {
            return
        }
        reportedBusy = busy
        let onBusy = onBusy
        Task { @MainActor in
            onBusy(busy)
        }
    }
}
