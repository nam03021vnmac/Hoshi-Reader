//
//  SasayakiChaptersTab.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct SasayakiChaptersTab: View {
    var player: SasayakiPlayer
    
    private var currentIndex: Int? {
        player.audiobookInfo.currentChapter(at: player.currentTime)?.index
    }
    
    var body: some View {
        let chapters = player.audiobookInfo.chapters
        ScrollViewReader { proxy in
            List {
                if chapters.isEmpty {
                    Text("No chapters found in this audiobook.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(chapters) { chapter in
                        SasayakiChapterRow(chapter: chapter, isCurrent: chapter.index == currentIndex) {
                            player.seek(to: chapter.startSeconds)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear {
                scrollToCurrent(proxy)
            }
            .onChange(of: chapters.count) { _, _ in
                scrollToCurrent(proxy)
            }
        }
    }
    
    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let currentIndex else {
            return
        }
        Task {
            proxy.scrollTo(currentIndex, anchor: .center)
        }
    }
}

private struct SasayakiChapterRow: View {
    let chapter: SasayakiAudiobookChapter
    let isCurrent: Bool
    let action: () -> Void
    
    private var title: String {
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "Chapter") : title
    }
    
    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(isCurrent ? .subheadline.weight(.semibold) : .subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if isCurrent {
                        Text("Current chapter")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                Spacer(minLength: 8)
                Text(SasayakiSheet.formatTime(chapter.startSeconds))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10)
                .fill(isCurrent ? Color(uiColor: .systemGray5) : Color.clear)
                .padding(.horizontal, 12)
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    }
}
