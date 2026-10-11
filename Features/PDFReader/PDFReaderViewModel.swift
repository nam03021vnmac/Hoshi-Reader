//
//  PDFReaderViewModel.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit
import SwiftUI

enum PDFReaderSheet: Identifiable {
    case contents
    case settings
    
    var id: Self { self }
}

@Observable
@MainActor
final class PDFReaderViewModel {
    let book: BookMetadata
    let rootURL: URL?
    let document: PDFDocument?
    let info: PDFInfo?
    var pageIndex: Int
    var activeSheet: PDFReaderSheet?
    
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    
    var pageCount: Int {
        info?.pageCount ?? 0
    }
    
    var coverURL: URL? {
        guard let rootURL, let cover = book.cover else {
            return nil
        }
        return rootURL.appendingPathComponent(cover)
    }
    
    init(book: BookMetadata) {
        self.book = book
        
        guard let pdf = book.pdf,
              let root = try? BookStorage.getBooksDirectory().appendingPathComponent(book.folder),
              let document = PDFDocument(url: root.appendingPathComponent(pdf)),
              document.pageCount > 0 else {
            self.rootURL = nil
            self.document = nil
            self.info = nil
            self.pageIndex = 0
            return
        }
        
        var info = BookStorage.loadPDFInfo(root: root)
        if info?.pageCount != document.pageCount {
            info = PDFInfo(pageCount: document.pageCount)
            try? BookStorage.save(info, inside: root, as: FileNames.pdfInfo)
        }
        
        let saved = BookStorage.loadBookmark(root: root)?.chapterIndex ?? 0
        self.rootURL = root
        self.document = document
        self.info = info
        self.pageIndex = min(max(saved, 0), document.pageCount - 1)
    }
    
    func pageChanged(to index: Int) {
        guard index != pageIndex else {
            return
        }
        pageIndex = index
        scheduleSave()
    }
    
    func jump(to index: Int) {
        guard let document, let page = document.page(at: min(max(index, 0), pageCount - 1)) else {
            return
        }
        pdfView?.go(to: page)
    }
    
    func saveBookmark() {
        saveTask?.cancel()
        saveTask = nil
        guard let rootURL else {
            return
        }
        let bookmark = Bookmark(
            chapterIndex: pageIndex,
            progress: 0,
            characterCount: pageIndex + 1,
            lastModified: Date()
        )
        try? BookStorage.save(bookmark, inside: rootURL, as: FileNames.bookmark)
    }
    
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else {
                return
            }
            self?.saveBookmark()
        }
    }
}
