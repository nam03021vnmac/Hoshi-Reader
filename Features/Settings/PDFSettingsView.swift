//
//  PDFSettingsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct PDFSettingsView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var previousPack: OCRModelPack?

    var body: some View {
        @Bindable var userConfig = userConfig
        List {
            Section("Display") {
                Picker("Page Mode", selection: $userConfig.pdfDisplayMode) {
                    Text("Paged").tag(PDFDisplayMode.paged)
                    Text("Continuous").tag(PDFDisplayMode.continuous)
                }

                Toggle("Right-to-Left Pages", isOn: $userConfig.pdfRightToLeft)
            }

            Section {
                Picker("OCR", selection: $userConfig.pdfOCRMode) {
                    Text("Auto").tag(PDFOCRMode.auto)
                    Text("Always").tag(PDFOCRMode.always)
                    Text("Off").tag(PDFOCRMode.off)
                }
                
                Stepper("Prefetch Pages: \(userConfig.pdfPrefetchPages)", value: $userConfig.pdfPrefetchPages, in: 0...5)
                    .disabled(userConfig.pdfOCRMode == .off)
            } header: {
                Text("Text Recognition")
            } footer: {
                Text("Auto recognizes pages without a usable text layer. Always ignores embedded text. Prefetched pages are recognized ahead of time while reading.")
            }

            Section {
                Picker("Model", selection: $userConfig.pdfOCRModel) {
                    ForEach(OCRModelPack.selectable) { pack in
                        Text(pack.title).tag(pack)
                    }
                }

                ForEach(OCRModelPack.supported) { pack in
                    OCRModelRow(pack: pack)
                }
            } header: {
                Text("OCR Model")
            } footer: {
                Text("Used for scanned pages without a text layer. Recognized pages are saved, so each page is only recognized once.")
            }

            #if DEBUG
            Section("Developer") {
                NavigationLink("OCR Test") {
                    OCRDebugView()
                }
            }
            #endif
        }
        .navigationTitle("PDF")
        .onAppear {
            OCRModelStore.shared.refresh()
        }
        .onChange(of: userConfig.pdfOCRModel) { old, _ in
            if OCRModelStore.shared.state(for: old) == .installed {
                previousPack = old
            }
        }
        .confirmationDialog(
            "Delete \(previousPack?.title ?? "")?",
            isPresented: Binding(
                get: { previousPack != nil },
                set: { if !$0 { previousPack = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let previousPack {
                    OCRModelStore.shared.delete(previousPack)
                }
                previousPack = nil
            }
            Button("Keep", role: .cancel) {
                previousPack = nil
            }
        } message: {
            Text("Pages recognized with the previous model are recognized again with the new one as you read.")
        }
    }
}

private struct OCRModelRow: View {
    let pack: OCRModelPack
    private var store: OCRModelStore { OCRModelStore.shared }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(OCRModelManifest.totalBytes(for: pack)), countStyle: .file)
    }

    private var status: String {
        switch store.state(for: pack) {
        case .installed:
            String(localized: "Installed")
        case .downloading:
            String(localized: "Downloading…")
        case .notInstalled, .failed:
            String(localized: "Not Downloaded")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.title)
                    Text("\(status) · \(size)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if pack == .v6Medium {
                        Text("Slower and a larger download")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if pack.isForManga {
                        Text("Only used for books set to the manga model in the reader menu")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                switch store.state(for: pack) {
                case .notInstalled, .failed:
                    Button("Download") {
                        store.download(pack)
                    }
                    .buttonStyle(.borderless)
                case .downloading:
                    Button("Cancel", role: .cancel) {
                        store.cancelDownload(pack)
                    }
                    .buttonStyle(.borderless)
                case .installed:
                    Button("Delete", role: .destructive) {
                        store.delete(pack)
                    }
                    .buttonStyle(.borderless)
                }
            }
            switch store.state(for: pack) {
            case .downloading(let progress):
                ProgressView(value: progress)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }
}
