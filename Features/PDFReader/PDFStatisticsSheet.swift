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
                    rows(charactersRead: viewModel.currentSession.charactersRead, readingSpeed: viewModel.currentSession.readingSpeed, readingTime: viewModel.currentSession.readingTime)
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
                    rows(charactersRead: viewModel.todaysTotal.charactersRead, readingSpeed: viewModel.todaysTotal.readingSpeed, readingTime: viewModel.todaysTotal.readingTime)
                } header: {
                    Text("Today")
                }

                Section {
                    rows(charactersRead: viewModel.allTimeTotal.charactersRead, readingSpeed: viewModel.allTimeTotal.readingSpeed, readingTime: viewModel.allTimeTotal.readingTime)
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
    private func rows(charactersRead: Int, readingSpeed: Int, readingTime: Double) -> some View {
        HStack {
            Text("Characters Read:")
            Spacer()
            Text("**\(charactersRead)**")
        }
        HStack {
            Text("Reading Speed:")
            Spacer()
            Text("**\(readingSpeed) / h**")
        }
        HStack {
            Text("Reading Time:")
            Spacer()
            Text("**\(Duration.seconds(readingTime).formatted())**")
        }
    }
}
