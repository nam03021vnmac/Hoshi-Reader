//
//  PDFStatisticsSheet.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct PDFStatisticsSheet: View {
    let viewModel: PDFReaderViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    rows(for: viewModel.sessionStatistics)
                } header: {
                    HStack {
                        Text("Session")
                        Button {
                            if viewModel.isTracking {
                                viewModel.stopTracking()
                            } else {
                                viewModel.startTracking()
                            }
                        } label: {
                            Image(systemName: viewModel.isTracking ? "pause.fill" : "play.fill")
                        }
                        .foregroundStyle(.primary)
                    }
                } footer: {
                    Text("Characters are counted when you turn past a page whose text has been recognized.")
                }

                Section {
                    rows(for: viewModel.todaysStatistics)
                } header: {
                    Text("Today")
                }

                Section {
                    rows(for: viewModel.allTimeStatistics)
                } header: {
                    Text("All Time")
                }
            }
            .monospacedDigit()
            .navigationTitle("Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        viewModel.activeSheet = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(for statistics: Statistics) -> some View {
        HStack {
            Text("Characters Read:")
            Spacer()
            Text("**\(statistics.charactersRead)**")
        }
        HStack {
            Text("Reading Speed:")
            Spacer()
            Text("**\(statistics.lastReadingSpeed) / h**")
        }
        HStack {
            Text("Reading Time:")
            Spacer()
            Text("**\(Duration.seconds(statistics.readingTime).formatted())**")
        }
    }
}
