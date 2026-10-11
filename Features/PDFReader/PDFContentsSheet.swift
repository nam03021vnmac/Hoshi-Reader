//
//  PDFContentsSheet.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit
import SwiftUI

struct PDFContentsSheet: View {
    let viewModel: PDFReaderViewModel
    let readerTheme: ColorScheme
    
    @Environment(\.dismiss) private var dismiss
    @State private var outline: [OutlineEntry] = []
    @State private var sliderValue: Double
    @State private var pageInput = ""
    @FocusState private var pageFieldFocused: Bool
    
    struct OutlineEntry: Identifiable {
        let id: Int
        let label: String
        let depth: Int
        let pageIndex: Int?
    }
    
    init(viewModel: PDFReaderViewModel, readerTheme: ColorScheme) {
        self.viewModel = viewModel
        self.readerTheme = readerTheme
        _sliderValue = State(initialValue: Double(viewModel.pageIndex + 1))
    }
    
    private var selectedPage: Int {
        Int(sliderValue.rounded())
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section("Go to page") {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Page")
                            Spacer()
                            TextField("", text: $pageInput)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .focused($pageFieldFocused)
                                .onSubmit { commitInput() }
                            Text("/ \(viewModel.pageCount)")
                                .foregroundStyle(.secondary)
                            Button("Go") {
                                commitInput()
                                go(to: selectedPage - 1)
                            }
                            .buttonStyle(.borderless)
                        }
                        
                        if viewModel.pageCount > 1 {
                            Slider(value: $sliderValue, in: 1...Double(viewModel.pageCount), step: 1) { editing in
                                if !editing {
                                    go(to: selectedPage - 1)
                                }
                            }
                        }
                    }
                }
                
                if !outline.isEmpty {
                    Section("Outline") {
                        ForEach(outline) { entry in
                            Button {
                                if let pageIndex = entry.pageIndex {
                                    go(to: pageIndex)
                                }
                            } label: {
                                HStack {
                                    Text(entry.label)
                                        .padding(.leading, CGFloat(entry.depth) * 16)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    if let pageIndex = entry.pageIndex {
                                        Text("\(pageIndex + 1)")
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(entry.pageIndex == nil)
                        }
                    }
                }
            }
            .navigationTitle(viewModel.book.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(readerTheme)
        .task {
            pageInput = String(selectedPage)
            outline = loadOutline()
        }
        .onChange(of: sliderValue) { _, _ in
            if !pageFieldFocused {
                pageInput = String(selectedPage)
            }
        }
    }
    
    private func commitInput() {
        pageFieldFocused = false
        if let value = Int(pageInput) {
            sliderValue = Double(min(max(value, 1), max(viewModel.pageCount, 1)))
        }
        pageInput = String(selectedPage)
    }
    
    private func go(to pageIndex: Int) {
        viewModel.jump(to: pageIndex)
        dismiss()
    }
    
    private func loadOutline() -> [OutlineEntry] {
        guard let document = viewModel.document, let root = document.outlineRoot else {
            return []
        }
        var entries: [OutlineEntry] = []
        
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else {
                    continue
                }
                var pageIndex: Int?
                if let page = child.destination?.page {
                    let index = document.index(for: page)
                    pageIndex = index == NSNotFound ? nil : index
                }
                entries.append(OutlineEntry(
                    id: entries.count,
                    label: child.label ?? "",
                    depth: depth,
                    pageIndex: pageIndex
                ))
                walk(child, depth: depth + 1)
            }
        }
        
        walk(root, depth: 0)
        return entries
    }
}
