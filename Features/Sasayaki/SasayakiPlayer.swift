//
//  SasayakiPlayer.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import LAME
import MediaPlayer
import SwiftUI

struct CueTimeline {
    private let cues: [SasayakiMatch]
    
    init(match: SasayakiMatchData? = nil) {
        cues = match?.matches ?? []
    }
    
    func nextCue(after time: Double) -> Double? {
        var index = findCue(time)
        if index < cues.count, cues[index].startTime == time {
            index += 1
        }
        return index < cues.count ? cues[index].startTime : nil
    }
    
    func prevCue(before time: Double) -> Double? {
        let index = findCue(time)
        return index > 0 ? cues[index - 1].startTime : nil
    }
    
    func cue(before time: Double) -> SasayakiMatch? {
        let index = findCue(time)
        return index > 0 ? cues[index - 1] : nil
    }
    
    func cue(at time: Double) -> SasayakiMatch? {
        let index = findCue(time)
        if index < cues.count, Swift.abs(cues[index].startTime - time) <= 0.01 {
            return cues[index]
        }
        if index == 0 {
            return nil
        }
        let cue = cues[index - 1]
        return time <= cue.endTime ? cue : nil
    }
    
    private func findCue(_ time: Double) -> Int {
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].startTime < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

@Observable
@MainActor
class SasayakiPlayer {
    private let skipInterval: TimeInterval = 15
    
    var errorMessage: String?
    var isRestoring = false
    
    var matchData: SasayakiMatchData?
    var timeline = CueTimeline()
    
    var playback = SasayakiPlaybackData(lastPosition: 0)
    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying = false {
        didSet {
            updateIdleTimerDisabled()
            #if os(macOS)
            updateNowPlayingInfo()
            #endif
        }
    }
    var stopPlaybackTime: Double?
    var pageRange: (start: Double, end: Double)?
    var lastUpdate = -1
    
    var delay: Double = 0 {
        didSet {
            guard !isRestoring else { return }
            savePlayback()
            updateCue(for: currentTime)
        }
    }
    var rate: Float = 1 {
        didSet {
            guard !isRestoring else { return }
            savePlayback()
            player?.defaultRate = rate
            if isPlaying {
                player?.rate = rate
            }
        }
    }
    var autoScroll: Bool { UserDefaults.standard.object(forKey: "sasayakiAutoScroll") as? Bool ?? true }
    var imagePause: Bool { UserDefaults.standard.object(forKey: "sasayakiImagePause") as? Bool ?? true }
    var imagePauseDuration: Double { UserDefaults.standard.object(forKey: "sasayakiImagePauseDuration") as? Double ?? 3 }
    var pageAdvance: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "sasayakiPageAdvance") && defaults.bool(forKey: "paragraphMode") && !defaults.bool(forKey: "continuousMode")
    }
    
    var currentCue: SasayakiMatch?
    var lastCue: SasayakiMatch?
    var pendingCue: SasayakiMatch?
    var pendingImage: SasayakiImage?
    var pausedOnImage = false
    var imageResumeCue: SasayakiMatch?
    var imagePauseTask: Task<Void, Never>?
    var chapterTransition = false
    var shouldResume = false
    var resumeAfterInterruption = false
    var hasPlayedOnce = false
    var player: AVPlayer?
    #if os(iOS)
    var nowPlayingSession: MPNowPlayingSession?
    #else
    var remoteCommandCenter: MPRemoteCommandCenter?
    #endif
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var interruptionObserver: NSObjectProtocol?
    var audioURL: URL?
    var artwork: MPMediaItemArtwork?
    var audiobookInfo: SasayakiAudiobookInfo = .empty
    private var audiobookInfoGeneration = 0
    
    var hasAudio: Bool { player != nil }
    var hasMatch: Bool { matchData != nil }
    var audioFileName: String? { audioURL?.lastPathComponent }
    
    let bookMetadata: BookMetadata?
    let rootURL: URL
    let bridge: WebViewBridge
    let loadChapter: (Int) -> Void
    let getCurrentIndex: () -> Int
    let onPlayback: () -> Void
    
    init(rootURL: URL, bridge: WebViewBridge, loadChapter: @escaping (Int) -> Void, getCurrentIndex: @escaping () -> Int, onPlayback: @escaping () -> Void) {
        self.rootURL = rootURL
        self.bridge = bridge
        self.loadChapter = loadChapter
        self.getCurrentIndex = getCurrentIndex
        self.onPlayback = onPlayback
        self.bookMetadata = BookStorage.loadMetadata(root: rootURL)
        
        matchData = BookStorage.loadSasayakiMatch(root: rootURL)
        timeline = CueTimeline(match: matchData)
        reloadPlayback()
    }
    
    func reloadPlayback() {
        isRestoring = true
        playback = BookStorage.loadSasayakiPlayback(root: rootURL) ?? SasayakiPlaybackData(lastPosition: 0)
        currentTime = playback.lastPosition
        delay = playback.delay
        rate = playback.rate
        lastUpdate = Int(currentTime.rounded(.down))
        
        if let player {
            player.defaultRate = rate
            
            if isPlaying {
                player.rate = rate
            }
            
            player.seek(
                to: CMTime(seconds: currentTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isRestoring = false
                }
            }
        } else {
            isRestoring = false
        }
    }
    
    func importAudio(from url: URL) throws {
        _ = url.startAccessingSecurityScopedResource()
        teardown()
        
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        playback.audioBookmark = bookmark
        savePlayback()
        
        audioURL = url
        errorMessage = nil
        setupPlayer(url: url)
    }
    
    func clearAudio() {
        teardown()
        playback.audioBookmark = nil
        savePlayback()
        errorMessage = nil
    }
    
    func applyMatch(_ match: SasayakiMatchData?) {
        let resume = pausedOnImage
        cancelImagePause()
        clearDisplayedCue()
        matchData = match
        timeline = CueTimeline(match: match)
        lastCue = nil
        pendingCue = nil
        pendingImage = nil
        imageResumeCue = nil
        if resume {
            startPlayback()
        }
    }
    
    func cues(for chapterIndex: Int) -> String {
        let cues = matchData?.matches
            .filter { $0.chapterIndex == chapterIndex }
            .sorted { $0.start < $1.start }
            .map { SasayakiCueRange(id: $0.id, start: $0.start, length: $0.length) } ?? []
        let data = try? JSONEncoder().encode(cues)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    
    func togglePlayback() {
        if pausedOnImage {
            cancelImagePause()
            startPlayback()
            return
        }
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
            if autoScroll, let currentCue {
                displayCue(currentCue, reveal: true)
            }
        }
    }
    
    func updateIdleTimerDisabled() {
        Platform.isIdleTimerDisabled = (isPlaying && autoScroll) || SasayakiMatchCoordinator.shared.isBusy
    }
    
    func nextCue() {
        guard hasMatch else {
            skip(forward: true)
            return
        }
        stopPlaybackTime = nil
        let next = timeline.nextCue(after: currentCue?.startTime ?? currentTime - delay)
        guard let next else { return }
        seek(seconds: next + delay)
    }
    
    func prevCue() {
        guard hasMatch else {
            skip(forward: false)
            return
        }
        stopPlaybackTime = nil
        let previous = timeline.prevCue(before: currentCue?.startTime ?? max(0, currentTime - delay)) ?? 0
        seek(seconds: previous + delay)
    }
    
    func skip(forward: Bool) {
        stopPlaybackTime = nil
        if forward {
            let target = self.currentTime + self.skipInterval
            seek(seconds: self.duration != 0 ? min(self.currentTime + self.skipInterval, self.duration) : target)
        } else {
            seek(seconds: max(0, self.currentTime - self.skipInterval))
        }
    }
    
    func seek(to seconds: Double) {
        stopPlaybackTime = nil
        var target = max(0, seconds)
        if duration > 0 {
            target = min(target, duration)
        }
        seek(seconds: target)
    }
    
    func handleRestoreCompleted(currentIndex: Int) {
        guard chapterTransition else { return }
        
        if let image = pendingImage, image.chapterIndex == currentIndex {
            chapterTransition = false
            pendingImage = nil
            scrollAndPause(image)
            return
        }
        
        let cue: SasayakiMatch?
        let reveal: Bool
        if let pendingCue, pendingCue.chapterIndex == currentIndex {
            cue = pendingCue
            reveal = autoScroll && hasPlayedOnce
        } else if let active = timeline.cue(at: currentTime - delay), active.chapterIndex == currentIndex {
            cue = active
            reveal = shouldResume && autoScroll
        } else {
            cue = nil
            reveal = false
        }
        
        let resume = shouldResume
        chapterTransition = false
        shouldResume = false
        pendingCue = nil
        
        if let cue {
            displayCue(cue, reveal: reveal)
        } else {
            clearDisplayedCue()
        }
        
        if resume {
            startPlayback()
        }
    }
    
    func prepareTransition() {
        // without cues there is nothing to re-sync after the chapter loads, so playback continues
        shouldResume = hasMatch && isPlaying
        chapterTransition = true
        stopPlaybackTime = nil
        clearDisplayedCue()
        if shouldResume {
            pausePlayback()
        }
    }
    
    func findCue(chapterIndex: Int, offset: Int) -> SasayakiMatch? {
        guard let matches = matchData?.matches else { return nil }
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            let m = matches[mid]
            if m.chapterIndex < chapterIndex || (m.chapterIndex == chapterIndex && m.start + m.length <= offset) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return (low < matches.count && matches[low].chapterIndex == chapterIndex && matches[low].start <= offset) ? matches[low] : nil
    }
    
    func playCue(from cue: SasayakiMatch, stop: Bool) {
        stopPlaybackTime = nil
        if isPlaying {
            pausePlayback()
        }
        seek(
            seconds: cue.startTime + delay,
            startPlayback: true,
            updateCue: false,
            stopPlaybackTime: stop ? cue.endTime + delay : nil
        )
    }
    
    func handlePageChanged(cueIds: [String], play: Bool?) {
        let ids = Set(cueIds)
        let cues = matchData?.matches.filter { ids.contains($0.id) } ?? []
        
        pageRange = nil
        if play != nil {
            stopPlaybackTime = nil
            if isPlaying {
                pausePlayback()
            }
        }
        
        guard let first = cues.min(by: { $0.startTime < $1.startTime }),
              let last = cues.max(by: { $0.startTime < $1.startTime }),
              var end = cues.map(\.endTime).max() else {
            return
        }
        if let next = timeline.nextCue(after: last.startTime) {
            end = min(end, max(next - 0.02, last.startTime))
        }
        
        var start = first.startTime
        if let prev = timeline.cue(before: first.startTime),
           first.start > (prev.chapterIndex == first.chapterIndex ? prev.start + prev.length : 0) {
            start = min(start, prev.endTime + 0.05)
        }
        pageRange = (start, end)
        
        if let play {
            seek(seconds: start + delay, startPlayback: play)
        }
    }
    
    func teardown() {
        cancelImagePause()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        
        if let token = timeObserver, let player {
            player.removeTimeObserver(token)
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        player = nil
        timeObserver = nil
        endObserver = nil
        interruptionObserver = nil
        isPlaying = false
        Task { await WordAudioPlayer.shared.setOtherAudioActive(false) }
        duration = 0
        stopPlaybackTime = nil
        artwork = nil
        audiobookInfo = .empty
        audiobookInfoGeneration += 1
        
        clearDisplayedCue()
        #if os(iOS)
        if let center = nowPlayingSession?.remoteCommandCenter {
            center.playCommand.removeTarget(nil)
            center.pauseCommand.removeTarget(nil)
            center.togglePlayPauseCommand.removeTarget(nil)
            center.previousTrackCommand.removeTarget(nil)
            center.nextTrackCommand.removeTarget(nil)
            center.skipBackwardCommand.removeTarget(nil)
            center.skipForwardCommand.removeTarget(nil)
            center.changePlaybackPositionCommand.removeTarget(nil)
        }
        nowPlayingSession = nil
        Task.detached {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        #else
        tearDownNowPlaying()
        #endif
        
        if let url = audioURL {
            url.stopAccessingSecurityScopedResource()
            audioURL = nil
        }
    }
    
    func cueSentenceAudio(_ cue: SasayakiMatch, sentence: String) async -> Data? {
        guard let url = audioURL else {
            return nil
        }
        
        let range = expandCue(cue, sentence: sentence)
        let start = max(0, range.start + delay)
        let end = max(start, range.end + delay)
        return await Task.detached(priority: .userInitiated) {
            Self.encodeClip(url: url, start: start, end: end)
        }.value
    }
    
    nonisolated private static func encodeClip(url: URL, start: Double, end: Double) -> Data? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false) else {
            return nil
        }
        let format = file.processingFormat
        let first = min(AVAudioFramePosition(start * format.sampleRate), file.length)
        let last = min(AVAudioFramePosition(end * format.sampleRate), file.length)
        guard last > first, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(last - first)) else {
            return nil
        }
        file.framePosition = first
        guard (try? file.read(into: buffer)) != nil, let data = buffer.int16ChannelData else {
            return nil
        }
        
        let frames = Int32(buffer.frameLength)
        let left = data[0]
        let right = data[Int(format.channelCount) - 1]
        let mono = memcmp(left, right, Int(frames) * MemoryLayout<Int16>.size) == 0
        let lame = lame_init()
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(format.sampleRate))
        lame_set_num_channels(lame, mono ? 1 : 2)
        lame_set_VBR(lame, vbr_mtrh)
        lame_set_VBR_quality(lame, 0)
        guard lame_init_params(lame) >= 0 else {
            return nil
        }
        
        let mp3 = [UInt8](unsafeUninitializedCapacity: Int(frames) * 5 / 4 + 7200) { output, count in
            let base = output.baseAddress!
            let encoded = Int(lame_encode_buffer(lame, left, right, frames, base, Int32(output.count)))
            count = encoded + Int(lame_encode_flush(lame, base + encoded, Int32(output.count - encoded)))
            lame_get_lametag_frame(lame, base, count)
        }
        return Data(mp3)
    }
    
    private func expandCue(_ cue: SasayakiMatch, sentence: String) -> (start: Double, end: Double) {
        guard let cues = matchData?.matches.filter({ $0.chapterIndex == cue.chapterIndex }),
              let index = cues.firstIndex(where: { $0.id == cue.id }) else {
            return (cue.startTime, cue.endTime)
        }
        
        var start = index
        var end = index
        let filteredSentence = sentence.filtered()
        while start > cues.startIndex, filteredSentence.contains(cues[start - 1].text.filtered()) { start -= 1 }
        while end < cues.index(before: cues.endIndex), filteredSentence.contains(cues[end + 1].text.filtered()) { end += 1 }
        return (cues[start].startTime, cues[end].endTime)
    }
    
    private func startPlayback() {
        guard let player else { return }
        setupNowPlayingSession()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        #endif
        player.play()
        isPlaying = true
        hasPlayedOnce = true
        Task { await WordAudioPlayer.shared.setOtherAudioActive(true) }
    }
    
    private func pausePlayback() {
        guard let player else { return }
        player.pause()
        isPlaying = false
    }
    
    private func tick(_ seconds: Double) {
        if isRestoring {
            return
        }
        
        let previousTime = currentTime
        currentTime = seconds
        
        if let duration = player?.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            self.duration = duration
        }
        
        if pageAdvance, let pageEnd = pageRange.map({ $0.end + delay }), previousTime < pageEnd, seconds >= pageEnd {
            if isPlaying {
                pausePlayback()
            }
            return
        }
        
        if let stopTime = stopPlaybackTime, seconds >= stopTime {
            stopPlaybackTime = nil
            if isPlaying {
                pausePlayback()
            }
        }
        
        let second = Int(seconds.rounded(.down))
        if second != lastUpdate {
            lastUpdate = second
            playback.lastPosition = seconds
            savePlayback()
            onPlayback()
        }
        
        updateCue(for: seconds)
    }
    
    private func seek(seconds: Double, startPlayback: Bool = false, updateCue: Bool = true, stopPlaybackTime: Double? = nil) {
        guard let player else { return }
        lastCue = nil
        cancelImagePause()
        if let pageRange, !(pageRange.start...pageRange.end).contains(seconds - delay) {
            self.pageRange = nil
        }
        
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopPlaybackTime = stopPlaybackTime
                if updateCue {
                    self.tick(seconds)
                } else {
                    self.currentTime = seconds
                }
                
                if startPlayback {
                    self.startPlayback()
                }
                #if os(macOS)
                self.updateNowPlayingInfo()
                #endif
            }
        }
    }
    
    private func setupPlayer(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.defaultRate = rate
        player?.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.125, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time.seconds) }
        }
        
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopPlaybackTime = nil
                self.isPlaying = false
            }
        }
        
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
                    else { return }
            let options = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleInterruption(type, options: options)
            }
        }
        #endif
        
        loadAudiobookInfo(from: item.asset)
    }
    
    private func setupNowPlayingSession() {
        #if os(iOS)
        guard let player, nowPlayingSession == nil else { return }
        let item = player.currentItem
        player.replaceCurrentItem(with: nil)
        nowPlayingSession = MPNowPlayingSession(players: [player])
        nowPlayingSession?.automaticallyPublishesNowPlayingInfo = true
        configureRemoteCommandCenter(nowPlayingSession!.remoteCommandCenter)
        player.replaceCurrentItem(with: item)
        nowPlayingSession?.becomeActiveIfPossible()
        #else
        setUpRemoteCommands()
        #endif
    }
    
    func restoreAudio() {
        guard hasMatch, let bookmark = playback.audioBookmark else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, relativeTo: nil, bookmarkDataIsStale: &isStale) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        if isStale {
            playback.audioBookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            savePlayback()
        }
        audioURL = url
        setupPlayer(url: url)
    }
    
    private func savePlayback() {
        playback.delay = delay
        playback.rate = rate
        if (try? BookStorage.savePlayback(&playback, root: rootURL)) == true {
            try? SyncStorage.shared.handleBookChange(folder: rootURL.lastPathComponent)
        }
    }
    
    private func updateCue(for time: Double) {
        guard hasAudio, hasMatch, !chapterTransition, !pausedOnImage else { return }
        
        let lookupTime = time - delay
        guard let cue = timeline.cue(at: lookupTime) else {
            clearDisplayedCue()
            return
        }
        
        if cue.id == currentCue?.id {
            return
        }
        
        if isPlaying, autoScroll, hasPlayedOnce, imagePause,
           let prev = lastCue, (cue.chapterIndex, cue.start) > (prev.chapterIndex, prev.start),
           let image = imageBetween(prev, cue) {
            beginImagePause(image: image, resume: cue)
            return
        }
        
        let currentIndex = getCurrentIndex()
        if cue.chapterIndex == currentIndex {
            displayCue(cue, reveal: autoScroll && hasPlayedOnce)
        } else if autoScroll, hasPlayedOnce {
            currentCue = cue
            pendingCue = cue
            loadChapter(cue.chapterIndex)
        } else {
            clearDisplayedCue()
        }
    }
    
    private func displayCue(_ cue: SasayakiMatch, reveal: Bool) {
        currentCue = cue
        lastCue = cue
        bridge.send(.highlightSasayakiCue(id: cue.id, reveal: reveal))
    }
    
    private func clearDisplayedCue() {
        guard currentCue != nil else { return }
        currentCue = nil
        bridge.send(.clearSasayakiCue)
    }
    
    private func imageBetween(_ prev: SasayakiMatch, _ next: SasayakiMatch) -> SasayakiImage? {
        matchData?.images.first { image in
            (image.chapterIndex, image.offset) >= (prev.chapterIndex, prev.start + prev.length) &&
            (image.chapterIndex, image.offset) <= (next.chapterIndex, next.start)
        }
    }
    
    private func beginImagePause(image: SasayakiImage, resume: SasayakiMatch) {
        pausedOnImage = true
        imageResumeCue = resume
        pausePlayback()
        if image.chapterIndex == getCurrentIndex() {
            scrollAndPause(image)
        } else {
            pendingImage = image
            loadChapter(image.chapterIndex)
        }
    }
    
    private func finishImagePause() {
        imagePauseTask?.cancel()
        imagePauseTask = nil
        pendingImage = nil
        pausedOnImage = false
        guard let resume = imageResumeCue else {
            startPlayback()
            return
        }
        imageResumeCue = nil
        if resume.chapterIndex == getCurrentIndex() {
            displayCue(resume, reveal: autoScroll && hasPlayedOnce)
            startPlayback()
        } else {
            currentCue = resume
            pendingCue = resume
            startPlayback()
            loadChapter(resume.chapterIndex)
        }
    }
    
    private func cancelImagePause() {
        guard pausedOnImage else { return }
        imagePauseTask?.cancel()
        imagePauseTask = nil
        pausedOnImage = false
        pendingImage = nil
        imageResumeCue = nil
        lastCue = nil
    }
    
    private func scrollAndPause(_ image: SasayakiImage) {
        bridge.send(.scrollToSasayakiImage(index: image.imageIndex) { [weak self] shouldPause in
            Task { @MainActor [weak self] in
                guard let self, self.pausedOnImage else { return }
                guard shouldPause else {
                    self.finishImagePause()
                    return
                }
                self.imagePauseTask?.cancel()
                self.imagePauseTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(self?.imagePauseDuration ?? 3))
                    guard !Task.isCancelled else { return }
                    self?.finishImagePause()
                }
            }
        })
    }
    
    #if os(iOS)
    private func handleInterruption(_ type: AVAudioSession.InterruptionType, options: UInt) {
        switch type {
        case .began:
            if pausedOnImage {
                cancelImagePause()
                resumeAfterInterruption = true
            } else {
                resumeAfterInterruption = isPlaying
            }
            resumeAfterInterruption = isPlaying
            pausePlayback()
        case .ended:
            if resumeAfterInterruption, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                resumeAfterInterruption = false
                startPlayback()
            }
        @unknown default:
            break
        }
    }
    #endif
    
    func configureRemoteCommandCenter(_ center: MPRemoteCommandCenter) {
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.startPlayback() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pausePlayback() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        if UserDefaults.standard.bool(forKey: "sasayakiSkipControls") {
            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
            center.skipBackwardCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.skip(forward: false) }
                return .success
            }
            center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
            center.skipForwardCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.skip(forward: true) }
                return .success
            }
            center.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.skip(forward: false) }
                return .success
            }
            center.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.skip(forward: true) }
                return .success
            }
        } else {
            center.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.prevCue() }
                return .success
            }
            center.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.nextCue() }
                return .success
            }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(seconds: event.positionTime) }
            return .success
        }
    }
    
    private func loadAudiobookInfo(from asset: AVAsset) {
        audiobookInfoGeneration += 1
        let generation = audiobookInfoGeneration
        Task {
            let info = await SasayakiAudiobookInfo.load(from: asset)
            // the audio was swapped or removed while loading
            guard generation == audiobookInfoGeneration else { return }
            audiobookInfo = info
            if duration == 0, let seconds = info.durationSeconds {
                duration = seconds
            }
            
            let image =
            info.artworkData.flatMap(PlatformImage.init(data:)) ??
            bookMetadata?.coverURL
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap(PlatformImage.init(data:))
            
            guard let image else { return }
            
            artwork = Self.makeArtwork(from: image)
            updateNowPlayingInfo()
        }
    }
    
    func updateNowPlayingInfo() {
        guard let item = player?.currentItem else { return }
        
        var info: [String: Any] = [:]
        
        if let title = bookMetadata?.displayTitle {
            info[MPMediaItemPropertyTitle] = title
        }
        if let artwork = artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        
        #if os(macOS)
        publishNowPlayingInfo(info)
        #else
        item.nowPlayingInfo = info
        #endif
    }
    
    private static nonisolated func makeArtwork(from image: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
