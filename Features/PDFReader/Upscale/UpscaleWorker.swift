//
//  UpscaleWorker.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import os
import PDFKit

/// Owns everything that takes long or isn't thread safe, so the scheduler stays free to react to page turns.
actor UpscaleWorker {
    enum Outcome: Sendable {
        case image(URL)
        case skipped
    }

    private static let modelName = "RealESRGANAnimeV3x2"
    private static let logger = Logger(subsystem: "HoshiReader", category: "Upscale")

    private let tiler = UpscaleTiler.animeV3
    private let cache: UpscaleCache
    private let screenLongSide: CGFloat
    // own instance, the PDFView's document isn't safe to share across threads
    private let document: PDFDocument?
    private var model: CoreMLTileModel?
    private var neuralEngineShare: Double?

    init(pdfURL: URL, cache: UpscaleCache, screenLongSide: CGFloat) {
        self.document = PDFDocument(url: pdfURL)
        self.cache = cache
        self.screenLongSide = screenLongSide
    }

    /// Failures leave a skip marker, so the page stays original and isn't tried again.
    /// Throws CancellationError when cancelled, which leaves nothing behind.
    func process(pageIndex: Int) async throws -> Outcome {
        do {
            return try await upscale(pageIndex: pageIndex)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("page \(pageIndex) stays original: \(String(describing: error), privacy: .public)")
            cache.markSkipped(page: pageIndex)
            return .skipped
        }
    }

    /// Whether the Neural Engine runs most of the model. A CPU-bound model is too slow to spend on pages ahead.
    func runsOnNeuralEngine() async -> Bool {
        _ = try? await loadedModel()
        guard let neuralEngineShare else {
            return true
        }
        return neuralEngineShare >= 0.9
    }

    func releaseModel() {
        model = nil
    }

    private func upscale(pageIndex: Int) async throws -> Outcome {
        guard let page = document?.page(at: pageIndex), let pageRef = page.pageRef else {
            throw UpscaleError.render
        }
        let bounds = page.bounds(for: .cropBox)
        let decision = UpscalePolicy.decide(
            PageResolutionProbe.probe(pageRef),
            pageLongSide: max(bounds.width, bounds.height),
            screenLongSide: screenLongSide
        )
        guard case .upscale(let inputLongSide) = decision else {
            Self.logger.info("page \(pageIndex) skipped: \(String(describing: decision), privacy: .public)")
            cache.markSkipped(page: pageIndex)
            return .skipped
        }

        let model = try await loadedModel()
        try Task.checkCancellation()
        guard let rendered = PageRenderer.render(page, longSide: inputLongSide),
              let source = UpscaleBitmap(image: rendered.image) else {
            throw UpscaleError.render
        }
        let monochrome = MonochromeGuard.isNeutral(source)
        let start = ContinuousClock.now
        var output = try tiler.upscale(source, model: model)
        Self.logger.info("page \(pageIndex): \(source.width)x\(source.height), monochrome \(monochrome), \(String(describing: ContinuousClock.now - start), privacy: .public)")
        if monochrome {
            MonochromeGuard.makeNeutral(&output)
        } else {
            MonochromeGuard.restoreColor(&output, source: source)
        }
        try Task.checkCancellation()
        guard let encoded = UpscaleCodec.encode(output, monochrome: monochrome) else {
            throw UpscaleError.encode
        }
        return .image(try cache.store(encoded.data, format: encoded.format, page: pageIndex))
    }

    private func loadedModel() async throws -> CoreMLTileModel {
        if let model {
            return model
        }
        guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
            throw UpscaleError.modelMissing
        }
        let loaded = try CoreMLTileModel(url: url, inputSize: tiler.inputSize, outputSize: tiler.inputSize * tiler.scale)
        if neuralEngineShare == nil {
            neuralEngineShare = await CoreMLTileModel.neuralEngineShare(url: url)
            Self.logger.info("Neural Engine share of ops: \(self.neuralEngineShare ?? -1)")
        }
        model = loaded
        return loaded
    }
}
