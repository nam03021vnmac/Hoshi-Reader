//
//  PDFOCRModelPrompt.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Offered when a page has no usable text layer and the selected OCR model isn't installed
struct PDFOCRModelPrompt: View {
    let pack: OCRModelPack
    let onDismiss: () -> Void
    private var store: OCRModelStore { OCRModelStore.shared }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(OCRModelManifest.totalBytes(for: pack)), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("Text Recognition")
                .font(.headline)

            Text("This page has no text. Download the OCR model to look up words on scanned pages.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("\(pack.title) · \(size)")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch store.state(for: pack) {
            case .notInstalled, .failed:
                if case .failed(let message) = store.state(for: pack) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button {
                    store.download(pack)
                } label: {
                    Text("Download")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button("Not Now", action: onDismiss)
            case .downloading(let progress):
                ProgressView(value: progress)
                Button("Cancel", role: .cancel) {
                    store.cancelDownload(pack)
                }
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Done", action: onDismiss)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .onAppear {
            store.refresh()
        }
    }
}
