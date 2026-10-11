//
//  PaddleOCREngine.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import OnnxRuntimeBindings
import os

nonisolated struct OCRModelPaths: Sendable {
    let det: URL
    let rec: URL
    let dict: URL
    let params: URL

    init(directory: URL) {
        det = directory.appendingPathComponent("det.onnx")
        rec = directory.appendingPathComponent("rec.onnx")
        dict = directory.appendingPathComponent("dict.txt")
        params = directory.appendingPathComponent("params.json")
    }

    var allExist: Bool {
        [det, rec, dict, params].allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}

nonisolated private enum OCRRuntime {
    // one ORT environment per process
    nonisolated(unsafe) static let environment: ORTEnv? = try? ORTEnv(loggingLevel: .error)
}

/// PaddleOCR (DB detection + CTC recognition) on ONNX Runtime. Sessions load lazily and can be
/// released under memory pressure; they reload on the next request.
actor PaddleOCREngine: OCREngine {
    nonisolated let identifier: String
    private let paths: OCRModelPaths
    private let threads: Int
    private var detector: DBTextDetector?
    private var recognizer: CTCTextRecognizer?

    init(identifier: String, paths: OCRModelPaths, threads: Int? = nil) {
        self.identifier = identifier
        self.paths = paths
        // 4 threads on devices with ≥ 8 GB, which report a little under 8 GiB
        self.threads = threads ?? (ProcessInfo.processInfo.physicalMemory >= 7 * 1024 * 1024 * 1024 ? 4 : 2)
    }

    func recognize(_ image: CGImage) async throws -> [OCRLine] {
        let (lines, timings) = try recognizeWithTimings(image)
        #if DEBUG
        OCRLog.logger.debug("\(self.identifier, privacy: .public): \(lines.count) lines, det \(timings.detection.milliseconds) ms, rec \(timings.recognition.milliseconds) ms")
        #endif
        return lines
    }

    func recognizeWithTimings(_ image: CGImage) throws -> (lines: [OCRLine], timings: OCRTimings) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        guard let pixels = PixelImage(image) else {
            throw OCRError.inference("unsupported image")
        }
        try loadSessions()
        guard let detector, let recognizer else {
            throw OCRError.runtimeUnavailable
        }
        let clock = ContinuousClock()
        var timings = OCRTimings()
        let start = clock.now
        let boxes = try detector.detect(pixels)
        let detected = clock.now
        timings.detection = detected - start
        let lines = try recognizer.recognize(pixels, boxes: boxes)
        timings.recognition = clock.now - detected
        return (lines, timings)
    }

    func releaseSessions() {
        detector = nil
        recognizer = nil
    }

    private func loadSessions() throws {
        guard detector == nil || recognizer == nil else {
            return
        }
        guard let environment = OCRRuntime.environment else {
            throw OCRError.runtimeUnavailable
        }
        guard paths.allExist else {
            throw OCRError.modelNotInstalled
        }
        let params = try OCRParams.load(from: paths.params)
        let dictionary = try Self.loadDictionary(paths.dict)

        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(Int32(threads))

        // hand the arena back after each run, pages are processed one at a time
        let runOptions = try ORTRunOptions()
        try runOptions.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")

        let detSession = try ORTSession(env: environment, modelPath: paths.det.path(percentEncoded: false), sessionOptions: options)
        let recSession = try ORTSession(env: environment, modelPath: paths.rec.path(percentEncoded: false), sessionOptions: options)
        let (detInput, detOutput) = try Self.names(of: detSession, model: "det")
        let (recInput, recOutput) = try Self.names(of: recSession, model: "rec")
        detector = DBTextDetector(session: detSession, inputName: detInput, outputName: detOutput, runOptions: runOptions, config: DBConfig(params: params.det))
        recognizer = CTCTextRecognizer(session: recSession, inputName: recInput, outputName: recOutput, runOptions: runOptions, config: CTCConfig(params: params.rec), dictionary: dictionary)
    }

    private static func names(of session: ORTSession, model: String) throws -> (input: String, output: String) {
        guard let input = try session.inputNames().first, let output = try session.outputNames().first else {
            throw OCRError.invalidModel("\(model) has no inputs or outputs")
        }
        return (input, output)
    }

    /// One entry per line; split on bytes so no entry merges with a line break
    static func loadDictionary(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if lines.last == "" {
            lines.removeLast()
        }
        guard !lines.isEmpty else {
            throw OCRError.invalidModel("dict.txt is empty")
        }
        return lines
    }
}

extension Duration {
    nonisolated var milliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
