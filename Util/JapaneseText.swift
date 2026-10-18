//
//  JapaneseText.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

// Swift port of the constants and logic in Features/Reader/ReaderWebView/selection.js, keep in sync

nonisolated enum JapaneseText {
    private static let ranges: [ClosedRange<UInt32>] = [
        0x3040...0x309f, // Hiragana
        0x30a0...0x30ff, // Katakana

        0x4e00...0x9fff, // CJK unified ideographs and extensions
        0x3400...0x4dbf,
        0x20000...0x2a6df,
        0x2a700...0x2b73f,
        0x2b740...0x2b81f,
        0x2b820...0x2ceaf,
        0x2ceb0...0x2ebef,
        0x30000...0x3134f,
        0x31350...0x323af,
        0x2ebf0...0x2ee5f,
        0xf900...0xfaff,
        0x2f800...0x2fa1f,

        0xff66...0xff9f, // Halfwidth katakana

        0x30fb...0x30fc, // Katakana punctuation
        0xff61...0xff65, // Kana punctuation

        0x3000...0x303f, // CJK punctuation
        0xff10...0xff19, // Fullwidth forms
        0xff21...0xff3a,
        0xff41...0xff5a,
        0xff01...0xff0f,
        0xff1a...0xff1f,
        0xff3b...0xff3f,
        0xff5b...0xff60,
        0xffe0...0xffee,
    ]

    static let scanDelimiters: Set<Character> = Set("。、！？…‥「」『』（）()【】〈〉《》〔〕｛｝{}［］[]：；:;，,.─\n\r")
    static let sentenceDelimiters: Set<Character> = Set("。！？.!?\n\r")
    static let trailingSentenceChars: Set<Character> = Set("。、！？」』）)】〉》〕｝}］]")
    static let brackets: [Character: Character] = [
        "「": "」", "『": "』", "（": "）", "(": ")", "【": "】", "〈": "〉", "《": "》", "〔": "〕", "｛": "｝", "{": "}", "［": "］", "[": "]"
    ]

    static func isCodePointJapanese(_ codePoint: UInt32) -> Bool {
        ranges.contains { $0.contains(codePoint) }
    }

    static func isJapanese(_ string: String) -> Bool {
        guard let scalar = string.unicodeScalars.first else {
            return false
        }
        return isCodePointJapanese(scalar.value)
    }

    /// Letters of space-separated scripts (English etc.), where a lookup has to start at the beginning of the word
    static func isWordCharacter(_ string: String) -> Bool {
        guard let first = string.first, string.count == 1, !isJapanese(string) else {
            return false
        }
        return first.isLetter || first.isNumber
    }

    static func isApostrophe(_ string: String) -> Bool {
        string == "'" || string == "\u{2019}"
    }

    static func isScanBoundary(_ string: String, scanNonJapaneseText: Bool) -> Bool {
        guard let first = string.first else {
            return true
        }
        if first.isWhitespace || first == "\u{3000}" {
            return true
        }
        if string.count == 1 && scanDelimiters.contains(first) {
            return true
        }
        return !scanNonJapaneseText && !isJapanese(string)
    }

    static func isWhitespace(_ string: String) -> Bool {
        !string.isEmpty && string.allSatisfy { $0.isWhitespace || $0 == "\u{3000}" }
    }

    /// Port of `getSentence`. `parts` are the grapheme clusters of one flat text and `index` is the selection start.
    /// `clozeOffset` is in UTF-16 units, as `AnkiManager.clozeParts` expects.
    static func sentence(in parts: [String], at index: Int) -> (sentence: String, clozeOffset: Int) {
        guard parts.indices.contains(index) else {
            return ("", 0)
        }

        func isIn(_ set: Set<Character>, _ part: String) -> Bool {
            part.count == 1 && set.contains(part.first!)
        }

        var start = 0
        for i in stride(from: index - 1, through: 0, by: -1) where isIn(sentenceDelimiters, parts[i]) {
            start = i + 1
            break
        }

        var end = parts.count
        for i in index..<parts.count where isIn(sentenceDelimiters, parts[i]) {
            end = i + 1
            while end < parts.count, isIn(trailingSentenceChars, parts[end]) {
                end += 1
            }
            break
        }

        let raw = Array(parts[start..<end])
        let prefixCount = index - start

        var lead = 0
        while lead < raw.count, isWhitespace(raw[lead]) {
            lead += 1
        }
        var tail = raw.count
        while tail > lead, isWhitespace(raw[tail - 1]) {
            tail -= 1
        }
        let sentence = Array(raw[lead..<tail])

        var stack: [Character] = []
        var unmatchedClose: [Character] = []
        let closeBrackets = Set(brackets.values)
        for part in sentence where part.count == 1 {
            let ch = part.first!
            if brackets[ch] != nil {
                stack.append(ch)
            } else if closeBrackets.contains(ch) {
                if let last = stack.last, brackets[last] == ch {
                    stack.removeLast()
                } else {
                    unmatchedClose.append(ch)
                }
            }
        }

        func character(_ i: Int) -> Character? {
            sentence[i].count == 1 ? sentence[i].first : nil
        }

        var startSlice = 0
        while !stack.isEmpty, startSlice < sentence.count - 1 {
            if stack[0] == character(startSlice) {
                stack.removeFirst()
            } else {
                break
            }
            startSlice += 1
        }

        var endSlice = sentence.count - 1
        var endIdx = sentence.count - 1
        while !unmatchedClose.isEmpty, endIdx > startSlice {
            if unmatchedClose.last == character(endIdx) {
                unmatchedClose.removeLast()
                endSlice = endIdx - 1
            } else if !isIn(sentenceDelimiters, sentence[endIdx]) {
                break
            }
            endIdx -= 1
        }

        guard startSlice <= endSlice else {
            return ("", 0)
        }
        var sliced = Array(sentence[startSlice...endSlice])
        var slicedLead = 0
        while slicedLead < sliced.count, isWhitespace(sliced[slicedLead]) {
            slicedLead += 1
        }
        sliced.removeFirst(slicedLead)
        while let last = sliced.last, isWhitespace(last) {
            sliced.removeLast()
        }

        let sentenceStart = lead + startSlice + slicedLead
        let clozeOffset = parts[(start + sentenceStart)..<max(start + sentenceStart, index)]
            .reduce(0) { $0 + $1.utf16.count }
        return (sliced.joined(), clozeOffset)
    }

    static func sentence(in text: String, at index: String.Index) -> (sentence: String, clozeOffset: Int) {
        let parts = text.map { String($0) }
        let offset = text.distance(from: text.startIndex, to: index)
        return sentence(in: parts, at: offset)
    }
}
