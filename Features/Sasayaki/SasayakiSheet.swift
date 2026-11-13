//
//  SasayakiSheet.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ImageIO
import SwiftUI

enum SasayakiSheetTab: CaseIterable, Identifiable {
    case resources
    case chapters
    case settings
    var id: Self { self }
    
    var title: LocalizedStringKey {
        switch self {
        case .resources: "Resources"
        case .chapters: "Chapters"
        case .settings: "Settings"
        }
    }
}

struct SasayakiSheet: View {
    var viewModel: ReaderViewModel
    let onDismiss: () -> Void
    
    @State private var tab: SasayakiSheetTab
    @State private var tabChosen = false
    @State private var height: CGFloat = 0
    
    init(viewModel: ReaderViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        let player = viewModel.sasayakiPlayer!
        _tab = State(initialValue: player.hasAudio && !player.audiobookInfo.chapters.isEmpty ? .chapters : .resources)
    }
    
    private var player: SasayakiPlayer {
        viewModel.sasayakiPlayer
    }
    
    // a short sheet, such as the medium detent or a phone in landscape, keeps most of its height for the tabs
    private var isCompact: Bool {
        height > 0 && height < 480
    }
    
    private var tabSelection: Binding<SasayakiSheetTab> {
        Binding {
            tab
        } set: { newTab in
            tab = newTab
            tabChosen = true
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    if player.hasAudio {
                        SasayakiPlaybackHeader(viewModel: viewModel, compact: isCompact)
                    }
                    
                    Picker("", selection: tabSelection) {
                        ForEach(SasayakiSheetTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
                #if os(macOS)
                .padding(.top, 12)
                #endif
                
                tabContent
                    .frame(maxHeight: .infinity)
                    .contentMargins(.top, 0, for: .scrollContent)
            }
            #if os(iOS)
            // the grouped forms below the header would otherwise sit on a different color than it
            .background(Color(uiColor: .systemGroupedBackground))
            #endif
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                height = newHeight
            }
            .onChange(of: player.audiobookInfo.chapters.isEmpty) { _, isEmpty in
                // the chapters load after the audio, so a sheet opened before then switches once they arrive
                if !isEmpty, !tabChosen, player.hasAudio, tab == .resources {
                    tab = .chapters
                }
            }
            .navigationTitle("Sasayaki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .sheetDismiss) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .resources:
            SasayakiResourcesTab(viewModel: viewModel) {
                tabChosen = true
            }
        case .chapters:
            SasayakiChaptersTab(player: player)
        case .settings:
            SasayakiSettingsTab(player: player)
        }
    }
    
    static func formatTime(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, seconds)) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, total % 60)
        }
        return String(format: "%d:%02d", minutes, total % 60)
    }
}

private struct SasayakiPlaybackHeader: View {
    @Environment(UserConfig.self) private var userConfig
    var viewModel: ReaderViewModel
    let compact: Bool
    
    @State private var scrubTime: Double?
    @State private var isScrubbing = false
    
    private var player: SasayakiPlayer {
        viewModel.sasayakiPlayer
    }
    
    private var title: String {
        if let title = player.audiobookInfo.title {
            return title
        }
        if let fileName = player.audioFileName {
            return (fileName as NSString).deletingPathExtension
        }
        return viewModel.sasayakiBookTitle
    }
    
    private var chapterTitle: String? {
        guard let chapter = player.audiobookInfo.currentChapter(at: player.currentTime) else {
            return nil
        }
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
    
    private var duration: Double {
        player.duration.isFinite ? max(0, player.duration) : 0
    }
    
    private var displayedTime: Double {
        scrubTime ?? min(max(0, player.currentTime), duration)
    }
    
    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            HStack(spacing: 12) {
                if !compact {
                    SasayakiCoverView(
                        artworkData: player.audiobookInfo.artworkData,
                        fallbackURL: viewModel.sasayakiCoverURL
                    )
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if !compact, let artist = player.audiobookInfo.artist {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let chapterTitle {
                        Text(chapterTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(compact ? 1 : 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            Slider(value: sliderValue, in: 0...max(duration, 1), onEditingChanged: scrubbingChanged)
                .disabled(duration <= 0)
            
            HStack(spacing: 8) {
                Text(SasayakiSheet.formatTime(displayedTime))
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                transportControls
                    .fixedSize()
                
                Text(SasayakiSheet.formatTime(duration))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(.secondary)
        }
        .onChange(of: player.currentTime) { _, time in
            if !isScrubbing, let target = scrubTime, Swift.abs(time - target) < 1.5 {
                scrubTime = nil
            }
        }
    }
    
    private var sliderValue: Binding<Double> {
        Binding {
            displayedTime
        } set: { value in
            if isScrubbing {
                scrubTime = value
            } else {
                player.seek(to: value)
            }
        }
    }
    
    private func scrubbingChanged(_ editing: Bool) {
        isScrubbing = editing
        guard !editing, let target = scrubTime else {
            return
        }
        // keeps the thumb at the target until the seek lands instead of jumping back
        player.seek(to: target)
        Task {
            try? await Task.sleep(for: .seconds(1))
            if !isScrubbing {
                scrubTime = nil
            }
        }
    }
    
    private var transportControls: some View {
        HStack(spacing: 14) {
            Button {
                userConfig.verticalWriting ? player.skip(forward: true) : player.skip(forward: false)
            } label: {
                Image(systemName: "15.arrow.trianglehead.counterclockwise")
            }
            
            Button {
                userConfig.verticalWriting ? player.nextCue() : player.prevCue()
            } label: {
                Image(systemName: "backward.fill")
            }
            
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30))
                    .frame(width: 34)
            }
            
            Button {
                userConfig.verticalWriting ? player.prevCue() : player.nextCue()
            } label: {
                Image(systemName: "forward.fill")
            }
            
            Button {
                userConfig.verticalWriting ? player.skip(forward: false) : player.skip(forward: true)
            } label: {
                Image(systemName: "15.arrow.trianglehead.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .font(.title2)
        .foregroundStyle(.secondary)
    }
}

private struct SasayakiCoverView: View {
    let artworkData: Data?
    let fallbackURL: URL?
    
    @State private var image: CGImage?
    
    private struct Source: Equatable {
        let artworkData: Data?
        let fallbackURL: URL?
    }
    
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "headphones")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: Source(artworkData: artworkData, fallbackURL: fallbackURL)) {
                image = Self.thumbnail(artworkData: artworkData, fallbackURL: fallbackURL)
            }
    }
    
    private static func thumbnail(artworkData: Data?, fallbackURL: URL?) -> CGImage? {
        let source = artworkData.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            ?? fallbackURL.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
        guard let source else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
