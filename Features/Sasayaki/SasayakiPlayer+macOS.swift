//
//  SasayakiPlayer+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import MediaPlayer

/// macOS has no MPNowPlayingSession, so the player drives the shared command center and
/// Now Playing info itself. That puts the book in Control Center's Now Playing and lets
/// the media keys play, pause and move between cues.
extension SasayakiPlayer {
    func setUpRemoteCommands() {
        guard remoteCommandCenter == nil else { return }
        let center = MPRemoteCommandCenter.shared()
        configureRemoteCommandCenter(center)
        remoteCommandCenter = center
    }

    func tearDownNowPlaying() {
        if let center = remoteCommandCenter {
            center.playCommand.removeTarget(nil)
            center.pauseCommand.removeTarget(nil)
            center.togglePlayPauseCommand.removeTarget(nil)
            center.previousTrackCommand.removeTarget(nil)
            center.nextTrackCommand.removeTarget(nil)
            center.skipBackwardCommand.removeTarget(nil)
            center.skipForwardCommand.removeTarget(nil)
            center.changePlaybackPositionCommand.removeTarget(nil)
        }
        remoteCommandCenter = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Adds the progress that MPNowPlayingSession publishes by itself on iOS. Called when
    /// playback starts, pauses or seeks; the system extrapolates the time in between.
    func publishNowPlayingInfo(_ info: [String: Any]) {
        // nothing has played yet, so there's nothing to show
        guard remoteCommandCenter != nil else { return }
        var info = info
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(rate)
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
#endif
