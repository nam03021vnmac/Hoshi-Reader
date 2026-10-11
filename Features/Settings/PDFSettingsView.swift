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
                Picker("Model", selection: $userConfig.pdfOCRModel) {
                    ForEach(OCRModelPack.supported) { pack in
                        Text(pack.title).tag(pack)
                    }
                }

                ForEach(OCRModelPack.supported) { pack in
                    OCRModelRow(pack: pack)
                }
            } header: {
                Text("OCR Model")
            } footer: {
                if OCRModelPack.v6Medium.isSupportedOnThisDevice {
                    Text("Used for scanned pages without a text layer. High accuracy is slower and a larger download.")
                } else {
                    Text("Used for scanned pages without a text layer.")
                }
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
    }
}

private struct OCRModelRow: View {
    let pack: OCRModelPack
    private var store: OCRModelStore { OCRModelStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.title)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(OCRModelManifest.totalBytes(for: pack)), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
