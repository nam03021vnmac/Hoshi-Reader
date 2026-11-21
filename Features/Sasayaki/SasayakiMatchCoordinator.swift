//
//  SasayakiMatchCoordinator.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import Foundation
import Speech

@Observable
@MainActor
final class SasayakiMatchCoordinator {
    static let shared = SasayakiMatchCoordinator()

    var progress: SasayakiTranscriptionProgress?
    var error: String?
    private(set) var runningRoot: URL?

    private var task: Task<Void, Never>?

    static var canTranscribe: Bool {
        if #available(iOS 26.0, macOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    var isBusy: Bool {
        task != nil
    }

    func isRunning(root: URL) -> Bool {
        guard task != nil, let runningRoot else {
            return false
        }
        return Self.sameRoot(runningRoot, root)
    }

    func runSubtitleMatch(rootURL: URL, srtURL: URL) throws -> SasayakiMatchData {
        let accessing = srtURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                srtURL.stopAccessingSecurityScopedResource()
            }
        }

        let srtData = try Data(contentsOf: srtURL)
        let cues = SasayakiParser.parseCues(from: srtData)
        let result = try SasayakiMatcher.match(rootURL: rootURL, cues: cues)
        try SyncStorage.shared.saveSasayakiMatch(result, folder: rootURL.lastPathComponent, root: rootURL)
        return result
    }

    func pause() {
        task?.cancel()
    }

    func cancel(root: URL) {
        if isRunning(root: root) {
            task?.cancel()
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    func startTranscription(rootURL: URL, audioURL: URL, onFinished: (@MainActor () -> Void)? = nil) {
        guard task == nil else {
            return
        }
        runningRoot = rootURL
        error = nil
        task = Task { @MainActor in
            Platform.isIdleTimerDisabled = true
            do {
                try await runTranscription(rootURL: rootURL, audioURL: audioURL)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            task = nil
            progress = nil
            runningRoot = nil
            Platform.isIdleTimerDisabled = false
            onFinished?()
        }
    }

    func clearTranscript(rootURL: URL) {
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(FileNames.sasayakiTranscript))
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func runTranscription(rootURL: URL, audioURL: URL) async throws {
        let accessing = audioURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                audioURL.stopAccessingSecurityScopedResource()
            }
        }

        let audio = try AVAudioFile(forReading: audioURL)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate

        var playback = BookStorage.loadSasayakiPlayback(root: rootURL) ?? SasayakiPlaybackData(lastPosition: 0)
        playback.audioBookmark = try? audioURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try? BookStorage.save(playback, inside: rootURL, as: FileNames.sasayakiPlayback)

        var transcript = SasayakiTranscript(through: 0, duration: duration, tokens: [])
        if let saved = BookStorage.loadSasayakiTranscript(root: rootURL), saved.duration == duration {
            transcript = saved
        }

        progress = .transcribing(through: transcript.through, duration: duration, remaining: nil)
        var lastPersist = Date()
        let startPosition = transcript.through
        var firstResultAt: Date?
        do {
            if !transcript.isComplete {
                try await SasayakiTranscriber.transcribe(file: audio, from: transcript.through) { fraction in
                    self.progress = .downloading(fraction)
                } onTokens: { tokens, through in
                    transcript.tokens.append(contentsOf: tokens)
                    transcript.through = through
                    let startedAt = firstResultAt ?? Date()
                    firstResultAt = startedAt
                    let elapsed = Date().timeIntervalSince(startedAt)
                    let processed = through - startPosition
                    let remaining = elapsed > 3 && processed > 30
                    ? (duration - through) * elapsed / processed
                    : nil
                    self.progress = .transcribing(through: through, duration: duration, remaining: remaining)
                    if Date().timeIntervalSince(lastPersist) > 15 {
                        lastPersist = Date()
                        try? BookStorage.save(transcript, inside: rootURL, as: FileNames.sasayakiTranscript)
                    }
                }
            }
        } catch is CancellationError {
        }

        guard !transcript.tokens.isEmpty else {
            return
        }
        try? BookStorage.save(transcript, inside: rootURL, as: FileNames.sasayakiTranscript)

        progress = .aligning
        let tokens = transcript.tokens
        let source = try SasayakiSource.build(rootURL: rootURL)
        let result = await Task.detached(priority: .userInitiated) {
            SasayakiAligner.align(source: source, tokens: tokens)
        }.value

        try SyncStorage.shared.saveSasayakiMatch(result, folder: rootURL.lastPathComponent, root: rootURL)
    }

    private static func sameRoot(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}
