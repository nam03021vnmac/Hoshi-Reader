//
//  SasayakiResourcesTab.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UniformTypeIdentifiers

struct SasayakiResourcesTab: View {
    var viewModel: ReaderViewModel
    let onImportAudio: () -> Void
    
    @State private var useTranscription = false
    @State private var isImporting = false
    @State private var importKind = ImportKind.audio
    @State private var subtitleFileName: String?
    @State private var isMatchingSubtitles = false
    @State private var subtitleError: String?
    @State private var transcript: SasayakiTranscript?
    @State private var showClearTranscript = false
    @State private var isExporting = false
    @State private var exportDocument: SasayakiSrtDocument?
    @State private var exportError: String?
    
    private enum ImportKind {
        case audio
        case subtitles
        
        var contentTypes: [UTType] {
            let extensions = switch self {
            case .audio: ["mp3", "m4b", "m4a", "mp4"]
            case .subtitles: ["srt", "txt"]
            }
            return extensions.compactMap { UTType(filenameExtension: $0) }
        }
    }
    
    private var player: SasayakiPlayer {
        viewModel.sasayakiPlayer
    }
    
    private var coordinator: SasayakiMatchCoordinator {
        SasayakiMatchCoordinator.shared
    }
    
    private var isTranscribing: Bool {
        viewModel.isSasayakiTranscribing
    }
    
    private var busyElsewhere: Bool {
        coordinator.isBusy && !isTranscribing
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Form {
                audiobookSection
                currentMatchSection
                
                if SasayakiMatchCoordinator.canTranscribe {
                    Section {
                        Picker("", selection: $useTranscription) {
                            Text("Subtitles").tag(false)
                            Text("Transcription").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(isTranscribing || isMatchingSubtitles)
                    }
                }
                
                if SasayakiMatchCoordinator.canTranscribe && useTranscription {
                    transcriptionSection
                } else {
                    subtitlesSection
                }
            }
            .formStyle(.grouped)
            .fileImporter(isPresented: $isImporting, allowedContentTypes: importKind.contentTypes) { result in
                guard case .success(let url) = result else {
                    return
                }
                switch importKind {
                case .audio:
                    importAudio(from: url)
                case .subtitles:
                    matchSubtitles(from: url)
                }
            }
            .alert("Clear transcription?", isPresented: $showClearTranscript) {
                Button("Clear", role: .destructive) {
                    viewModel.clearSasayakiTranscript()
                    transcript = nil
                    coordinator.error = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only clears transcription data, match is kept.")
            }
            .alert("Export SRT", isPresented: Binding {
                exportError != nil
            } set: { presented in
                if !presented {
                    exportError = nil
                }
            }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .sasayakiSrt,
            defaultFilename: SasayakiSrt.fileName(title: viewModel.sasayakiBookTitle)
        ) { result in
            if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                exportError = error.localizedDescription
            }
        }
        .onAppear {
            transcript = viewModel.loadSasayakiTranscript()
            if isTranscribing {
                useTranscription = true
            }
        }
        .onChange(of: isTranscribing) { _, running in
            if running {
                useTranscription = true
            } else {
                transcript = viewModel.loadSasayakiTranscript()
            }
        }
    }
    
    private var audiobookSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audiobook")
                        .font(.headline)
                    Group {
                        if player.hasAudio, let fileName = player.audioFileName {
                            Text(fileName)
                        } else {
                            Text("Select a .mp3, .m4b, or .m4a audiobook")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
                
                Spacer(minLength: 0)
                
                Group {
                    if player.hasAudio {
                        Button("Remove", role: .destructive) {
                            viewModel.clearSasayakiAudio()
                        }
                    } else {
                        Button("Open") {
                            importKind = .audio
                            isImporting = true
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isTranscribing || isMatchingSubtitles)
            }
            
            if let errorMessage = player.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
    }
    
    private var currentMatchSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Match")
                        .font(.headline)
                    Group {
                        if let coverage {
                            Text(coverage)
                        } else {
                            Text("No match")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                
                Spacer(minLength: 0)
                
                Button("Export SRT") {
                    exportSubtitles()
                }
                .buttonStyle(.borderless)
                .disabled(player.matchData?.matches.isEmpty ?? true)
            }
        }
    }
    
    private var subtitlesSection: some View {
        Section {
            HStack(spacing: 12) {
                Text("File")
                Spacer(minLength: 0)
                Group {
                    if let subtitleFileName {
                        Text(subtitleFileName)
                    } else {
                        Text("No file selected")
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                Button {
                    importKind = .subtitles
                    isImporting = true
                } label: {
                    if isMatchingSubtitles {
                        Text("Matching…")
                    } else {
                        Text("Open")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isMatchingSubtitles || isTranscribing)
            }
            
            if let subtitleError {
                Text(subtitleError)
                    .foregroundStyle(.red)
            }
        }
    }
    
    private var transcriptionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if isTranscribing {
                        ProgressView()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusLabel)
                            .fontWeight(.medium)
                            .monospacedDigit()
                        if let progressDetail {
                            Text(progressDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                if let progressFraction {
                    ProgressView(value: progressFraction)
                }
                
                if !isTranscribing, let transcript, transcript.duration > 0 {
                    Text("Transcribed \(timeString(transcript.through)) / \(timeString(transcript.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 4)
            
            if isTranscribing {
                Button("Pause") {
                    viewModel.pauseSasayakiTranscription()
                }
            } else {
                Button(actionTitle) {
                    viewModel.startSasayakiTranscription()
                }
                .disabled(!player.hasAudio || coordinator.isBusy || isMatchingSubtitles)
                
                if transcript != nil {
                    Button("Clear Transcription", role: .destructive) {
                        showClearTranscript = true
                    }
                }
            }
            
            if !busyElsewhere, let error = coordinator.error {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }
    
    private var coverage: String? {
        let characterCount = viewModel.sasayakiCharacterCount
        guard let match = player.matchData, characterCount > 0 else {
            return nil
        }
        let matched = match.matchedCharacters
        let percentage = (Double(matched) / Double(characterCount)) * 100
        return "\(matched)/\(characterCount) (\(String(format: "%.1f%%", percentage)))"
    }
    
    private var actionTitle: LocalizedStringKey {
        guard let transcript else {
            return "Transcribe"
        }
        if transcript.isComplete {
            return "Match Again"
        }
        return transcript.through > 0 ? "Resume" : "Transcribe"
    }
    
    private var statusLabel: String {
        if isTranscribing {
            switch coordinator.progress {
            case .downloading(let fraction):
                return String(localized: "Downloading model… \(Int(fraction * 100))%")
            case .transcribing(let through, let duration, _):
                guard duration > 0 else {
                    return String(localized: "Transcribing…")
                }
                return String(localized: "Transcribing \(timeString(through)) / \(timeString(duration))")
            case .aligning:
                return String(localized: "Aligning…")
            case nil:
                return String(localized: "Matching…")
            }
        }
        if busyElsewhere {
            return String(localized: "Another book is being transcribed.")
        }
        if !player.hasAudio {
            return String(localized: "Import an audiobook using the Audiobook section above.")
        }
        if let transcript, transcript.isComplete {
            return String(localized: "Transcription complete")
        }
        if let transcript, transcript.through > 0 {
            return String(localized: "Transcription paused")
        }
        return String(localized: "Transcribe Japanese audio and match it to the book.")
    }
    
    private var progressDetail: String? {
        guard isTranscribing, case .transcribing(_, _, let remaining) = coordinator.progress, let remaining else {
            return nil
        }
        if remaining < 60 {
            return String(localized: "less than 1 min left")
        }
        let minutes = Int((remaining / 60).rounded(.up))
        return String(localized: "about \(minutes) min left")
    }
    
    private var progressFraction: Double? {
        if isTranscribing {
            switch coordinator.progress {
            case .downloading(let fraction):
                return min(max(fraction, 0), 1)
            case .transcribing(let through, let duration, _) where duration > 0:
                return min(max(through / duration, 0), 1)
            default:
                return nil
            }
        }
        guard let transcript, transcript.duration > 0 else {
            return nil
        }
        return min(max(transcript.through / transcript.duration, 0), 1)
    }
    
    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    
    private func importAudio(from url: URL) {
        onImportAudio()
        do {
            try viewModel.importSasayakiAudio(from: url)
        } catch {
            player.errorMessage = error.localizedDescription
        }
    }
    
    private func matchSubtitles(from url: URL) {
        subtitleFileName = url.lastPathComponent
        subtitleError = nil
        isMatchingSubtitles = true
        Task {
            // matching blocks the main thread, so let the sheet show that it started first
            try? await Task.sleep(for: .milliseconds(50))
            do {
                try viewModel.matchSasayakiSubtitles(from: url)
            } catch {
                subtitleError = error.localizedDescription
            }
            isMatchingSubtitles = false
        }
    }
    
    private func exportSubtitles() {
        guard let match = player.matchData else {
            return
        }
        do {
            exportDocument = SasayakiSrtDocument(text: try SasayakiSrt.encode(match))
            isExporting = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}

nonisolated struct SasayakiSrtDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.sasayakiSrt] }
    
    let text: String
    
    init(text: String) {
        self.text = text
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UTType {
    nonisolated static var sasayakiSrt: UTType {
        UTType(filenameExtension: "srt", conformingTo: .plainText) ?? .plainText
    }
}
