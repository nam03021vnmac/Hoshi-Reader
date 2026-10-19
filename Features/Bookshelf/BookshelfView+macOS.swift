//
//  BookshelfView+macOS.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import SwiftUI

extension Notification.Name {
    /// Posted by File > Import Books… to open the book importer.
    static let importBooks = Notification.Name("HoshiImportBooks")
}

extension View {
    /// Mac-only ways into the library: dropping files onto the window, and File > Import Books….
    func macLibraryImport(viewModel: BookshelfViewModel, selectedTab: Binding<Int>) -> some View {
        modifier(MacLibraryImportModifier(viewModel: viewModel, selectedTab: selectedTab))
    }
}

private struct MacLibraryImportModifier: ViewModifier {
    var viewModel: BookshelfViewModel
    @Binding var selectedTab: Int
    @State private var isDropTargeted = false

    private static let bookExtensions: Set<String> = ["epub", "pdf"]
    private static let ankiExtensions: Set<String> = ["colpkg", "apkg"]

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                importDropped(urls)
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .overlay {
                if isDropTargeted {
                    dropHighlight
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .importBooks)) { _ in
                selectedTab = 0
                viewModel.isImporting = true
            }
    }

    private var dropHighlight: some View {
        ZStack {
            Rectangle()
                .fill(.background.opacity(0.6))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(12)
            Label("Drop to Import", systemImage: "square.and.arrow.down")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .allowsHitTesting(false)
    }

    private func importDropped(_ urls: [URL]) -> Bool {
        let fileURLs = urls.filter(\.isFileURL)
        let books = fileURLs.filter { Self.bookExtensions.contains($0.pathExtension.lowercased()) }
        let backups = fileURLs.filter { Self.ankiExtensions.contains($0.pathExtension.lowercased()) }
        guard !books.isEmpty || !backups.isEmpty else {
            return false
        }

        for backup in backups {
            do {
                try AnkiManager.shared.importAnkiBackup(from: backup)
            } catch {
                viewModel.errorMessage = error.localizedDescription
                viewModel.shouldShowError = true
            }
        }
        if !books.isEmpty {
            selectedTab = 0
            viewModel.importBooks(result: .success(books))
        }
        return true
    }
}
#endif
