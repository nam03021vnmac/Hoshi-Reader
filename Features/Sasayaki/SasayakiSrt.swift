//
//  SasayakiSrt.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

nonisolated enum SasayakiSrt {
    nonisolated enum ExportError: LocalizedError {
        case noValidCues

        var errorDescription: String? {
            String(localized: "No valid matched subtitles to export")
        }
    }

    private static let maxFileNameBytes = 180

    static func encode(_ data: SasayakiMatchData) throws -> String {
        var count = 0
        var result = ""
        for cue in data.matches.sorted(by: { $0.startTime < $1.startTime }) {
            guard cue.startTime.isFinite, cue.endTime.isFinite,
                  cue.startTime >= 0, cue.endTime > cue.startTime,
                  cue.endTime < Double(Int64.max) / 1000 else {
                continue
            }
            let text = cue.text
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .filter { !$0.allSatisfy(\.isWhitespace) }
                .joined(separator: "\n")
            if text.isEmpty {
                continue
            }

            let start = Int64((cue.startTime * 1000).rounded())
            let end = max(Int64((cue.endTime * 1000).rounded()), start + 1)
            count += 1
            result += "\(count)\n\(timestamp(start)) --> \(timestamp(end))\n\(text)\n\n"
        }
        guard count > 0 else {
            throw ExportError.noValidCues
        }
        return result
    }

    static func fileName(title: String) -> String {
        let safe = title
            .replacingOccurrences(of: "[\\p{Cc}\\\\/:*?\"<>|]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        var base = ""
        var bytes = 0
        for character in safe {
            let size = String(character).utf8.count
            if bytes + size > maxFileNameBytes {
                break
            }
            base.append(character)
            bytes += size
        }
        if base.allSatisfy(\.isWhitespace) {
            base = "subtitles"
        }
        return "\(base).srt"
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        String(
            format: "%02lld:%02lld:%02lld,%03lld",
            milliseconds / 3_600_000,
            milliseconds / 60_000 % 60,
            milliseconds / 1000 % 60,
            milliseconds % 1000
        )
    }
}
