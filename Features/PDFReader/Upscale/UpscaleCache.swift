//
//  UpscaleCache.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Caches/PageUpscale/<book folder>/page-00012-<config key>.png, plus .skip markers for pages that stay original.
/// In Caches so manual book backups don't grow, and so iOS can reclaim it; that only costs processing pages again.
nonisolated struct UpscaleCache: Sendable {
    static let maxBytes: Int64 = 1024 * 1024 * 1024
    /// bump when the pipeline's output changes, older files are left for the trim to remove
    private static let pipelineRevision = 1
    private static let modelIdentifier = "animev3-1"

    let directory: URL
    let configKey: String

    static var rootDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PageUpscale", isDirectory: true)
    }

    init?(bookFolder: String, pdfURL: URL, tiler: UpscaleTiler) {
        guard let root = Self.rootDirectory else {
            return nil
        }
        self.directory = root.appendingPathComponent(bookFolder, isDirectory: true)
        let values = try? pdfURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        self.configKey = [
            "p\(Self.pipelineRevision)",
            Self.modelIdentifier,
            "x\(tiler.scale)",
            "t\(tiler.inputSize)",
            "m\(tiler.padding)",
            "i\(Int(UpscalePolicy.maxInputLongSide))",
            "\(size)",
            "\(modified)",
        ].joined(separator: "-")
    }

    private func baseName(_ page: Int) -> String {
        String(format: "page-%05d-", page) + configKey
    }

    func imageURL(page: Int) -> URL? {
        for format in UpscaleCodec.Format.allCases {
            let url = directory.appendingPathComponent(baseName(page) + "." + format.rawValue)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    func isSkipped(page: Int) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(baseName(page) + ".skip").path)
    }

    func store(_ data: Data, format: UpscaleCodec.Format, page: Int) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(baseName(page) + "." + format.rawValue)
        try data.write(to: url, options: .atomic)
        return url
    }

    func markSkipped(page: Int) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: directory.appendingPathComponent(baseName(page) + ".skip"))
    }

    /// Keeps recently read pages through the trim
    func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func removeBook(folder: String) {
        guard let root = rootDirectory else {
            return
        }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(folder, isDirectory: true))
    }

    static func removeAll() {
        guard let root = rootDirectory else {
            return
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func files() -> [(url: URL, size: Int64, modified: Date)] {
        guard let root = rootDirectory,
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else {
            return []
        }
        var result: [(url: URL, size: Int64, modified: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }
            result.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        return result
    }

    static func totalBytes() -> Int64 {
        files().reduce(0) { $0 + $1.size }
    }

    /// Removes the least recently used pages until the cache fits
    static func trim(limit: Int64 = maxBytes) {
        let files = files().sorted { $0.modified < $1.modified }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where total > limit {
            guard (try? FileManager.default.removeItem(at: file.url)) != nil else {
                continue
            }
            total -= file.size
        }
    }
}
