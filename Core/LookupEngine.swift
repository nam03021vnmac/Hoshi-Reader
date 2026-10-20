//
//  LookupEngine.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CHoshiDicts

class LookupEngine {
    static let shared = LookupEngine()
    
    private nonisolated final class Bundle: @unchecked Sendable {
        var dictQuery = DictionaryQuery()
        var deinflector = Deinflector()
        var lookup: Lookup!
        
        init(termPaths: [URL], freqPaths: [URL], pitchPaths: [URL], kanjiPaths: [URL]) {
            for path in termPaths {
                dictQuery.add_term_dict(std.string(path.path(percentEncoded: false)))
            }
            for path in freqPaths {
                dictQuery.add_freq_dict(std.string(path.path(percentEncoded: false)))
            }
            for path in pitchPaths {
                dictQuery.add_pitch_dict(std.string(path.path(percentEncoded: false)))
            }
            for path in kanjiPaths {
                dictQuery.add_kanji_dict(std.string(path.path(percentEncoded: false)))
            }
            lookup = Lookup(&dictQuery, &deinflector)
        }
    }
    
    private var bundle: Bundle?
    private var generation = 0
    private var buildTask: Task<Void, Never>?
    
    private init() {}
    
    func buildQuery(termPaths: [URL], freqPaths: [URL], pitchPaths: [URL], kanjiPaths: [URL]) {
        generation += 1
        let token = generation
        let previous = buildTask
        buildTask = Task.detached(priority: .userInitiated) {
            await previous?.value
            guard await MainActor.run(body: { token == self.generation }) else { return }
            let newBundle = Bundle(termPaths: termPaths, freqPaths: freqPaths, pitchPaths: pitchPaths, kanjiPaths: kanjiPaths)
            await MainActor.run {
                guard token == self.generation else { return }
                self.bundle = newBundle
            }
        }
    }
    
    func lookup(_ str: String, maxResults: Int = 16, scanLength: Int = 16) -> [LookupResult] {
        guard let bundle else { return [] }
        let config = UserConfig.shared
        var options = LookupOptions()
        options.frequency_order = config.frequencySortOrder.lookupFrequencyOrder
        if config.frequencySortOrder.usesDictionary && !config.frequencySortDictionary.isEmpty {
            options.set_frequency_dictionary(std.string(config.frequencySortDictionary))
        }
        var results = Array(bundle.lookup.lookup(std.string(str), Int32(maxResults), scanLength, options))

        // dictionaries match case-sensitively, so "The" or "READING" at the start of a sentence would miss "the" and "reading"
        let variants = Self.caseVariants(of: str)
        guard !variants.isEmpty else {
            return results
        }
        var seen = Set(results.map { Self.key(of: $0) })
        for variant in variants {
            for var result in bundle.lookup.lookup(std.string(variant), Int32(maxResults), scanLength, options) {
                guard seen.insert(Self.key(of: result)).inserted else {
                    continue
                }
                // show and highlight the text as written, not the case-folded variant
                let length = String(result.matched).count
                result.matched = std.string(String(str.prefix(length)))
                results.append(result)
            }
        }
        // stable sort: the longest match wins, the as-written results stay ahead of the case-folded ones on ties
        let sorted = results.enumerated().sorted {
            let lhs = String($0.element.matched).count
            let rhs = String($1.element.matched).count
            return lhs != rhs ? lhs > rhs : $0.offset < $1.offset
        }
        return sorted.prefix(maxResults).map(\.element)
    }

    private static func key(of result: LookupResult) -> String {
        "\(String(result.term.expression))\u{0}\(String(result.term.reading))"
    }

    /// "The" → ["the"], "READING" → ["reading", "Reading"], text without uppercase letters → []
    private static func caseVariants(of str: String) -> [String] {
        let lowercased = str.lowercased()
        // only fold when it keeps the length, so a match maps back onto the text as written
        guard lowercased != str, lowercased.count == str.count else {
            return []
        }
        var variants = [lowercased]
        if let first = str.first {
            let capitalized = String(first) + str.dropFirst().lowercased()
            if capitalized != str, capitalized != lowercased, capitalized.count == str.count {
                variants.append(capitalized)
            }
        }
        return variants
    }
    
    func queryKanji(_ kanji: String) -> [String: Any]? {
        guard let bundle else { return nil }
        let result = bundle.dictQuery.query_kanji(std.string(kanji))
        var entries: [[String: Any]] = []
        for entry in result.entries {
            var meanings: [String] = []
            for definition in entry.definitions {
                meanings.append(String(definition))
            }
            entries.append([
                "dictName": String(entry.dict_name),
                "onyomi": String(entry.onyomi),
                "kunyomi": String(entry.kunyomi),
                "meanings": meanings,
            ])
        }
        guard !entries.isEmpty else { return nil }
        return [
            "character": String(result.character),
            "entries": entries,
        ]
    }
    
    func getStyles() -> [DictionaryStyle] {
        guard let bundle else { return [] }
        return Array(bundle.dictQuery.get_styles())
    }
    
    func withMediaFile<T>(dictName: String, mediaPath: String, _ body: (Data) -> T) -> T {
        guard let bundle else { return body(Data()) }
        let view = bundle.dictQuery.get_media_file_view(std.string(dictName), std.string(mediaPath))
        let size = Int(view.size)
        guard size > 0, let ptr = UnsafeMutableRawPointer(mutating: view.data) else {
            return body(Data())
        }
        let data = Data(bytesNoCopy: ptr, count: size, deallocator: .none)
        return body(data)
    }
    
    func getMediaFile(dictName: String, mediaPath: String) -> Data {
        return withMediaFile(dictName: dictName, mediaPath: mediaPath) { Data($0) }
    }
}
