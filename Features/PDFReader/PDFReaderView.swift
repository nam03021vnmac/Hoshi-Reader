//
//  PDFReaderView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit
import SwiftUI

// placeholder until the full reader lands
struct PDFReaderView: View {
    @Environment(\.dismissReader) private var dismissReader
    let book: BookMetadata
    
    private var pdfURL: URL? {
        guard let pdf = book.pdf,
              let booksFolder = try? BookStorage.getBooksDirectory() else {
            return nil
        }
        return booksFolder.appendingPathComponent(book.folder).appendingPathComponent(pdf)
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let pdfURL {
                PlainPDFView(url: pdfURL)
                    .ignoresSafeArea()
            } else {
                Color(.systemBackground).ignoresSafeArea()
                Text("Couldn't open book")
                    .foregroundStyle(.secondary)
            }
            
            Button {
                dismissReader?()
            } label: {
                Image(systemName: "chevron.left")
                    .padding(12)
                    .background(.regularMaterial, in: Circle())
            }
            .padding()
        }
    }
}

private struct PlainPDFView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displaysRTL = true
        view.document = PDFDocument(url: url)
        return view
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) { }
}
