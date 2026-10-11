//
//  OCRModelStore.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Synchronization
import UIKit

nonisolated enum OCRModelPack: String, CaseIterable, Codable, Identifiable, Sendable {
    case v6Small = "ppocrv6-small"
    case v6Medium = "ppocrv6-medium"
    case v5Mobile = "ppocrv5-mobile"

    // 8 GB devices report a little under 8 GiB
    static let minimumMemoryForMedium: UInt64 = 7 * 1024 * 1024 * 1024

    var id: String { rawValue }

    var isSupportedOnThisDevice: Bool {
        self != .v6Medium || ProcessInfo.processInfo.physicalMemory >= Self.minimumMemoryForMedium
    }

    static var supported: [OCRModelPack] {
        allCases.filter(\.isSupportedOnThisDevice)
    }

    var title: String {
        switch self {
        case .v6Small:
            String(localized: "Standard (PP-OCRv6 small)")
        case .v6Medium:
            String(localized: "High accuracy (PP-OCRv6 medium)")
        case .v5Mobile:
            String(localized: "Legacy (PP-OCRv5 mobile)")
        }
    }
}

nonisolated struct OCRModelFile: Sendable {
    enum Source: Sendable {
        case remote(URL)
        /// resource in the app bundle
        case bundled(String)
    }

    let name: String
    let source: Source
    let sha256: String
    let bytes: Int

    var isRemote: Bool {
        if case .remote = source {
            return true
        }
        return false
    }
}

nonisolated enum OCRModelManifest {
    /// bump when any file changes
    static let revision = 1

    // The ONNX models are downloaded from PaddlePaddle's Hugging Face repos, pinned to a commit and
    // checked against SHA-256. dict.txt and params.json are derived by Scripts/ocr/make_pack.py and
    // ship in the app bundle (Features/PDFReader/OCR/Packs).
    private static func huggingFace(_ repo: String, _ commit: String) -> URL {
        URL(string: "https://huggingface.co/PaddlePaddle/\(repo)/resolve/\(commit)/inference.onnx")!
    }

    static func files(for pack: OCRModelPack) -> [OCRModelFile] {
        switch pack {
        case .v6Small: [
            OCRModelFile(name: "det.onnx", source: .remote(huggingFace("PP-OCRv6_small_det_onnx", "28fe5895c24fd108c19eb3e8479f4ab385fbfc62")),
                         sha256: "d73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e", bytes: 9880512),
            OCRModelFile(name: "rec.onnx", source: .remote(huggingFace("PP-OCRv6_small_rec_onnx", "b8f84f0b80c529de40b4fbb3544b84fa7233a513")),
                         sha256: "5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634", bytes: 21159378),
            OCRModelFile(name: "dict.txt", source: .bundled("ppocrv6-small-dict.txt"),
                         sha256: "b5f2bfe2bdd9448429e3e82b51c789775d9b42f2403d082b00662eb77e401c5d", bytes: 74947),
            OCRModelFile(name: "params.json", source: .bundled("ppocrv6-small-params.json"),
                         sha256: "f9ee78dee2e91e21808ccd6e82cd38219c137e5a179bfaf9196e4b1a8b021452", bytes: 654),
        ]
        case .v6Medium: [
            OCRModelFile(name: "det.onnx", source: .remote(huggingFace("PP-OCRv6_medium_det_onnx", "61323801669c338b7891481ec7bac61ce31b576a")),
                         sha256: "eb13b44b25bb36f89528b68720af8a61d9cf381176107f465db1757b65d086e1", bytes: 62032837),
            OCRModelFile(name: "rec.onnx", source: .remote(huggingFace("PP-OCRv6_medium_rec_onnx", "50c7eacafc52fa7bcf4194e8cd08e46f8558504b")),
                         sha256: "9c09abf0957f7968c7586464b7397b84ad2387a0497a351af40e9acc71b673ba", bytes: 76554979),
            OCRModelFile(name: "dict.txt", source: .bundled("ppocrv6-medium-dict.txt"),
                         sha256: "b5f2bfe2bdd9448429e3e82b51c789775d9b42f2403d082b00662eb77e401c5d", bytes: 74947),
            OCRModelFile(name: "params.json", source: .bundled("ppocrv6-medium-params.json"),
                         sha256: "0e5df4e595ccf2fb8f1efa88cd687d3dc1ba97743b01169852aed813bea1fd69", bytes: 655),
        ]
        case .v5Mobile: [
            OCRModelFile(name: "det.onnx", source: .remote(huggingFace("PP-OCRv5_mobile_det_onnx", "e6f4fa85f00e168c862bc462aebca69eef9b3d3d")),
                         sha256: "a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d", bytes: 4826518),
            OCRModelFile(name: "rec.onnx", source: .remote(huggingFace("PP-OCRv5_mobile_rec_onnx", "ed152b8b495f84de93cda5709d768548a9127622")),
                         sha256: "da72dc72ca4dc220df0dfde68c1dedc31c58d3e76a25871122e5056227d50092", bytes: 16534782),
            OCRModelFile(name: "dict.txt", source: .bundled("ppocrv5-mobile-dict.txt"),
                         sha256: "d1979e9f794c464c0d2e0b70a7fe14dd978e9dc644c0e71f14158cdf8342af1b", bytes: 74012),
            OCRModelFile(name: "params.json", source: .bundled("ppocrv5-mobile-params.json"),
                         sha256: "69bdb060a2faf73c8eef30ac50af837abcb19114cdac137271c9bb1c7a5e10be", bytes: 654),
        ]
        }
    }

    /// Download size
    static func totalBytes(for pack: OCRModelPack) -> Int {
        files(for: pack).filter(\.isRemote).reduce(0) { $0 + $1.bytes }
    }

    /// Stored as PDFTextLayer.engine, so switching packs re-OCRs cached pages
    static func engineIdentifier(for pack: OCRModelPack) -> String {
        "\(pack.rawValue)-\(revision)"
    }
}

nonisolated enum OCRModelStoreError: LocalizedError {
    case checksumMismatch(String)
    case badResponse(Int)
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let file):
            String(localized: "\(file) is corrupted, please try again")
        case .badResponse(let status):
            String(localized: "Download failed (HTTP \(status))")
        case .missingResource(let file):
            String(localized: "\(file) is missing from the app")
        }
    }
}

@Observable @MainActor
final class OCRModelStore {
    static let shared = OCRModelStore()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    private(set) var states: [OCRModelPack: State] = [:]
    private var downloads: [OCRModelPack: Task<Void, Never>] = [:]
    private var engine: PaddleOCREngine?

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseEngineSessions()
            }
        }
    }

    func state(for pack: OCRModelPack) -> State {
        states[pack] ?? .notInstalled
    }

    func refresh() {
        for pack in OCRModelPack.allCases where downloads[pack] == nil {
            states[pack] = Self.installedPaths(for: pack) == nil ? .notInstalled : .installed
        }
    }

    /// Application Support/OCRModels/<pack>/
    nonisolated static func directory(for pack: OCRModelPack) -> URL? {
        rootDirectory?.appendingPathComponent(pack.rawValue, isDirectory: true)
    }

    nonisolated static var rootDirectory: URL? {
        (try? BookStorage.getAppDirectory())?.appendingPathComponent("OCRModels", isDirectory: true)
    }

    nonisolated static func installedPaths(for pack: OCRModelPack) -> OCRModelPaths? {
        // dev fallback: a <pack>/ folder reference in the app bundle
        if let bundled = Bundle.main.url(forResource: pack.rawValue, withExtension: nil) {
            let paths = OCRModelPaths(directory: bundled)
            if paths.allExist {
                return paths
            }
        }
        guard let directory = directory(for: pack) else {
            return nil
        }
        let paths = OCRModelPaths(directory: directory)
        return paths.allExist ? paths : nil
    }

    /// The engine for `pack`, if it's installed. Only one pack is kept loaded at a time.
    func engine(for pack: OCRModelPack) -> PaddleOCREngine? {
        let identifier = OCRModelManifest.engineIdentifier(for: pack)
        if let engine, engine.identifier == identifier {
            return engine
        }
        guard let paths = Self.installedPaths(for: pack) else {
            return nil
        }
        releaseEngineSessions()
        engine = PaddleOCREngine(identifier: identifier, paths: paths)
        return engine
    }

    func releaseEngineSessions() {
        guard let engine else {
            return
        }
        Task {
            await engine.releaseSessions()
        }
    }

    func download(_ pack: OCRModelPack) {
        guard downloads[pack] == nil else {
            return
        }
        states[pack] = .downloading(0)
        downloads[pack] = Task {
            do {
                try await install(pack)
                states[pack] = .installed
            } catch is CancellationError {
                states[pack] = .notInstalled
            } catch let error as URLError where error.code == .cancelled {
                states[pack] = .notInstalled
            } catch {
                states[pack] = .failed(error.localizedDescription)
            }
            downloads[pack] = nil
        }
    }

    func cancelDownload(_ pack: OCRModelPack) {
        downloads[pack]?.cancel()
    }

    func delete(_ pack: OCRModelPack) {
        cancelDownload(pack)
        if let engine, engine.identifier == OCRModelManifest.engineIdentifier(for: pack) {
            releaseEngineSessions()
            self.engine = nil
        }
        if let directory = Self.directory(for: pack) {
            try? FileManager.default.removeItem(at: directory)
        }
        refresh()
    }

    private func install(_ pack: OCRModelPack) async throws {
        guard let root = Self.rootDirectory, let destination = Self.directory(for: pack) else {
            throw BookStorage.BookStorageError.appDirectoryNotFound
        }
        let staging = root.appendingPathComponent(".staging-\(pack.rawValue)", isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: staging)
        }
        try Self.excludeFromBackup(root)

        let files = OCRModelManifest.files(for: pack)
        let total = Double(OCRModelManifest.totalBytes(for: pack))
        var completed = 0
        for file in files {
            guard case .remote(let url) = file.source else {
                continue
            }
            let offset = completed
            let temp = try await Self.download(url) { [weak self] received in
                let fraction = Double(offset + Int(received)) / total
                Task { @MainActor in
                    guard let self, case .downloading(let current) = self.states[pack], fraction - current >= 0.005 || fraction >= 1 else {
                        return
                    }
                    self.states[pack] = .downloading(min(fraction, 1))
                }
            }
            try Task.checkCancellation()
            guard try await Self.sha256(of: temp) == file.sha256 else {
                try? fileManager.removeItem(at: temp)
                throw OCRModelStoreError.checksumMismatch(file.name)
            }
            try fileManager.moveItem(at: temp, to: staging.appendingPathComponent(file.name))
            completed += file.bytes
        }
        for file in files {
            guard case .bundled(let resource) = file.source else {
                continue
            }
            guard let url = Bundle.main.url(forResource: resource, withExtension: nil) else {
                throw OCRModelStoreError.missingResource(resource)
            }
            guard try await Self.sha256(of: url) == file.sha256 else {
                throw OCRModelStoreError.checksumMismatch(file.name)
            }
            try fileManager.copyItem(at: url, to: staging.appendingPathComponent(file.name))
        }

        if engine?.identifier == OCRModelManifest.engineIdentifier(for: pack) {
            releaseEngineSessions()
            engine = nil
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
        try Self.excludeFromBackup(destination)
    }

    nonisolated private static func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = DownloadProgressDelegate(handler: progress)
        let (temp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw OCRModelStoreError.badResponse(http.statusCode)
        }
        // the system deletes `temp` once this returns
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temp, to: kept)
        return kept
    }

    @concurrent
    nonisolated private static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

nonisolated private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let handler: @Sendable (Int64) -> Void
    private let observation = Mutex<NSKeyValueObservation?>(nil)

    init(handler: @escaping @Sendable (Int64) -> Void) {
        self.handler = handler
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let handler = handler
        let token = task.progress.observe(\.completedUnitCount) { progress, _ in
            handler(progress.completedUnitCount)
        }
        observation.withLock { $0 = token }
    }
}
