//
//  SasayakiAudiobookInfo.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import Foundation

nonisolated struct SasayakiAudiobookChapter: Identifiable, Hashable, Sendable {
    let index: Int
    let title: String
    let startSeconds: Double
    let endSeconds: Double?

    var id: Int { index }
}

nonisolated struct SasayakiAudiobookInfo: Sendable {
    var title: String?
    var artist: String?
    var artworkData: Data?
    var chapters: [SasayakiAudiobookChapter]
    var durationSeconds: Double?

    static let empty = SasayakiAudiobookInfo(title: nil, artist: nil, artworkData: nil, chapters: [], durationSeconds: nil)

    static func load(from asset: AVAsset) async -> SasayakiAudiobookInfo {
        var info = SasayakiAudiobookInfo.empty

        if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 {
            info.durationSeconds = duration
        }

        let common = (try? await asset.load(.commonMetadata)) ?? []
        info.title = await string(for: .commonIdentifierTitle, in: common)
        info.artist = await string(for: .commonIdentifierArtist, in: common)
        if info.artist == nil {
            info.artist = await string(for: .commonIdentifierAuthor, in: common)
        }

        info.artworkData = await artwork(in: common)
        if info.artworkData == nil {
            let metadata = (try? await asset.load(.metadata)) ?? []
            info.artworkData = await artwork(in: metadata)
        }

        info.chapters = await loadChapters(from: asset, duration: info.durationSeconds)
        return info
    }

    func currentChapter(at seconds: Double) -> SasayakiAudiobookChapter? {
        guard seconds >= 0 else {
            return nil
        }
        let last = chapters.last
        return chapters.last { chapter in
            guard seconds >= chapter.startSeconds else {
                return false
            }
            guard let end = chapter.endSeconds else {
                return true
            }
            return chapter == last ? seconds <= end : seconds < end
        }
    }

    private static func loadChapters(from asset: AVAsset, duration: Double?) async -> [SasayakiAudiobookChapter] {
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        // files without chapter locales still expose their chapters through the preferred languages
        var languages = Locale.preferredLanguages
        languages.append(contentsOf: locales.map { $0.identifier(.bcp47) })
        guard let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages) else {
            return []
        }

        var raw: [(start: Double, end: Double?, title: String)] = []
        for group in groups {
            let start = group.timeRange.start.seconds
            guard start.isFinite else {
                continue
            }
            let end = group.timeRange.end.seconds
            let title = await string(for: .commonIdentifierTitle, in: group.items) ?? ""
            raw.append((max(0, start), end.isFinite && end > start ? end : nil, title))
        }
        raw.sort { $0.start < $1.start }

        return raw.enumerated().map { index, chapter in
            let next = index + 1 < raw.count ? raw[index + 1].start : nil
            let fallback = duration.flatMap { $0 >= chapter.start ? $0 : nil }
            return SasayakiAudiobookChapter(
                index: index,
                title: chapter.title,
                startSeconds: chapter.start,
                endSeconds: next ?? chapter.end ?? fallback
            )
        }
    }

    private static func string(for identifier: AVMetadataIdentifier, in items: [AVMetadataItem]) async -> String? {
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
            let value = try? await item.load(.stringValue)
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func artwork(in items: [AVMetadataItem]) async -> Data? {
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), !data.isEmpty {
                return data
            }
        }
        return nil
    }
}
