//
//  OCRDebugView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if DEBUG
import os
import PDFKit
import SwiftUI

/// Developer entry point: runs OCR on one page of a PDF book and shows the lines and timings
struct OCRDebugView: View {
    @State private var books: [BookMetadata] = []
    @State private var selectedBook: BookMetadata?
    @State private var pageCount = 1
    @State private var page = 1
    @State private var pack: OCRModelPack = .v6Small
    @State private var isRunning = false
    @State private var result: OCRDebugResult?
    @State private var errorMessage: String?
    @State private var showGlyphs = false

    var body: some View {
        List {
            Section {
                Picker("Book", selection: $selectedBook) {
                    Text("None").tag(BookMetadata?.none)
                    ForEach(books) { book in
                        Text(book.displayTitle).tag(Optional(book))
                    }
                }
                Stepper("Page \(page) of \(pageCount)", value: $page, in: 1...max(pageCount, 1))
                Picker("Model", selection: $pack) {
                    ForEach(OCRModelPack.allCases) { pack in
                        Text(pack.title).tag(pack)
                    }
                }
                Button {
                    run()
                } label: {
                    if isRunning {
                        ProgressView()
                    } else {
                        Text("Run OCR")
                    }
                }
                .disabled(selectedBook == nil || isRunning)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if let result {
                Section("Timings") {
                    LabeledContent("Render", value: "\(result.render.milliseconds) ms")
                    LabeledContent("Detection", value: "\(result.timings.detection.milliseconds) ms")
                    LabeledContent("Recognition", value: "\(result.timings.recognition.milliseconds) ms")
                    LabeledContent("Total", value: "\((result.render + result.timings.total).milliseconds) ms")
                    LabeledContent("Memory footprint", value: ByteCountFormatter.string(fromByteCount: Int64(result.footprint), countStyle: .memory))
                    LabeledContent("Peak footprint (process)", value: ByteCountFormatter.string(fromByteCount: Int64(result.peakFootprint), countStyle: .memory))
                }

                Section("Reading Order (\(result.layer.characterCount) characters)") {
                    Text(result.layer.lines.filter { !$0.isRuby }.map(\.text).joined())
                        .textSelection(.enabled)
                }

                Section("Page") {
                    Toggle("Show Glyph Cells", isOn: $showGlyphs)
                    OCRDebugImage(result: result, showGlyphs: showGlyphs)
                }

                Section("Lines (\(result.lines.count))") {
                    ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading) {
                            Text(line.text)
                            Text("\(line.isVertical ? "vertical" : "horizontal"), \(line.confidence, format: .number.precision(.fractionLength(2))), \(Int(line.bounds.minX)),\(Int(line.bounds.minY)) \(Int(line.bounds.width))×\(Int(line.bounds.height))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("OCR Test")
        .task {
            books = ((try? BookStorage.loadAllBooks()) ?? []).filter { $0.format == .pdf }
            if selectedBook == nil {
                selectedBook = books.first
            }
        }
        .onChange(of: selectedBook) {
            page = 1
            pageCount = selectedBook.flatMap { Self.pdfURL(for: $0) }.flatMap { PDFDocument(url: $0)?.pageCount } ?? 1
        }
    }

    private func run() {
        guard let book = selectedBook, let url = Self.pdfURL(for: book) else {
            return
        }
        guard let engine = OCRModelStore.shared.engine(for: pack) else {
            errorMessage = OCRError.modelNotInstalled.localizedDescription
            return
        }
        let pageIndex = page - 1
        isRunning = true
        errorMessage = nil
        Task {
            defer {
                isRunning = false
            }
            do {
                let (rendered, renderTime) = try await Self.render(url: url, pageIndex: pageIndex)
                let (lines, timings) = try await engine.recognizeWithTimings(rendered.image)
                let layer = OCRTextLayerBuilder.layer(from: lines, pixelToPage: rendered.pixelToPage, pageIndex: pageIndex, engine: engine.identifier)
                let (footprint, peak) = Self.memoryFootprint()
                result = OCRDebugResult(image: rendered.image, render: renderTime, timings: timings, lines: lines, layer: layer, footprint: footprint, peakFootprint: peak)
                OCRLog.logger.debug("page \(pageIndex + 1): render \(renderTime.milliseconds) ms, det \(timings.detection.milliseconds) ms, rec \(timings.recognition.milliseconds) ms, footprint \(footprint / 1_048_576) MB, peak \(peak / 1_048_576) MB")
                for line in layer.lines {
                    OCRLog.logger.debug("[\(line.blockIndex)\(line.isRuby ? " ruby" : "", privacy: .public)] \(line.text, privacy: .public)")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func pdfURL(for book: BookMetadata) -> URL? {
        guard let pdf = book.pdf, let root = try? BookStorage.getBooksDirectory().appendingPathComponent(book.folder) else {
            return nil
        }
        return root.appendingPathComponent(pdf)
    }

    @concurrent
    nonisolated private static func render(url: URL, pageIndex: Int) async throws -> (RenderedPage, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex),
              let rendered = PageRenderer.render(page, longSide: PageRenderer.ocrLongSide) else {
            throw OCRError.inference("could not render the page")
        }
        return (rendered, clock.now - start)
    }

    nonisolated private static func memoryFootprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            return (0, 0)
        }
        return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
    }
}

private struct OCRDebugResult {
    let image: CGImage
    let render: Duration
    let timings: OCRTimings
    let lines: [OCRLine]
    let layer: PDFTextLayer
    let footprint: UInt64
    let peakFootprint: UInt64
}

private struct OCRDebugImage: View {
    let result: OCRDebugResult
    let showGlyphs: Bool

    var body: some View {
        Image(decorative: result.image, scale: 1)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geometry in
                    let scale = geometry.size.width / CGFloat(result.image.width)
                    Path { path in
                        for line in result.lines {
                            path.addRect(line.bounds.applying(CGAffineTransform(scaleX: scale, y: scale)))
                        }
                    }
                    .stroke(.blue, lineWidth: 1)
                    if showGlyphs {
                        Path { path in
                            for line in result.lines {
                                for glyph in line.glyphs {
                                    path.addRect(glyph.rect.applying(CGAffineTransform(scaleX: scale, y: scale)))
                                }
                            }
                        }
                        .stroke(.orange.opacity(0.7), lineWidth: 0.5)
                    }
                }
            }
    }
}
#endif
