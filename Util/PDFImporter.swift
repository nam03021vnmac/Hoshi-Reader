//
//  PDFImporter.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit
import UIKit

nonisolated enum PDFImportError: LocalizedError {
    case unreadable
    case passwordProtected
    case empty
    
    var errorDescription: String? {
        switch self {
        case .unreadable:
            return String(localized: "Could not open PDF")
        case .passwordProtected:
            return String(localized: "Password-protected PDFs are not supported")
        case .empty:
            return String(localized: "PDF has no pages")
        }
    }
}

struct PDFImporter {
    nonisolated private static let coverLongSide: CGFloat = 768

    /// Renders the page, or only `region` of it (in page space), into the book folder and returns the path for `BookMetadata.cover`
    nonisolated static func writeCover(_ page: PDFPage, region: CGRect? = nil, folder: String, fileName: String) throws -> String? {
        guard let rendered = PageRenderer.render(page, longSide: coverLongSide, region: region),
              let data = UIImage(cgImage: rendered.image).jpegData(compressionQuality: 0.85) else {
            return nil
        }
        let bookFolder = try BookStorage.getBooksDirectory().appendingPathComponent(folder)
        try data.write(to: bookFolder.appendingPathComponent(fileName), options: .atomic)
        return "Books/\(folder)/\(fileName)"
    }

    static func importPDF(from sourceURL: URL, originalName: String) throws {
        guard let document = PDFDocument(url: sourceURL) else {
            throw PDFImportError.unreadable
        }
        if document.isLocked {
            throw PDFImportError.passwordProtected
        }
        guard document.pageCount > 0 else {
            throw PDFImportError.empty
        }
        
        let fallbackTitle = (originalName as NSString).deletingPathExtension
        let title = resolveTitle(
            attribute: document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
            fallback: fallbackTitle
        )
        let author = (document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        let safeTitle = BookStorage.sanitizeFileName(title)
        let bookFolder = try BookStorage.getBooksDirectory().appendingPathComponent(safeTitle)
        if FileManager.default.fileExists(atPath: bookFolder.path(percentEncoded: false)) {
            return
        }
        
        let baseName = BookStorage.sanitizeFileName(fallbackTitle)
        let fileName = (baseName.isEmpty ? "document" : baseName) + ".pdf"
        
        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        do {
            try BookStorage.copyFile(from: sourceURL, to: "Books/\(safeTitle)/\(fileName)")
            
            let coverPath = try document.page(at: 0).flatMap { try writeCover($0, folder: safeTitle, fileName: "cover.jpg") }

            let metadata = BookMetadata(
                title: title,
                author: author?.isEmpty == false ? author : nil,
                pdf: fileName,
                cover: coverPath,
                folder: safeTitle,
                lastAccess: Date()
            )
            let bookInfo = BookInfo(characterCount: document.pageCount, chapterInfo: [:], images: [])
            
            try BookStorage.save(metadata, inside: bookFolder, as: FileNames.metadata)
            try BookStorage.save(bookInfo, inside: bookFolder, as: FileNames.bookinfo)
            try BookStorage.save(PDFInfo(pageCount: document.pageCount), inside: bookFolder, as: FileNames.pdfInfo)
        } catch {
            try? BookStorage.delete(at: bookFolder)
            throw error
        }
        
        StatisticsStorage.restore(folder: safeTitle)
    }
    
    private static func resolveTitle(attribute: String?, fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedFallback.isEmpty ? "document" : trimmedFallback
        
        guard let title = attribute?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              !looksLikeJunk(title, fileName: fallbackTitle) else {
            return fallbackTitle
        }
        return title
    }
    
    private static func looksLikeJunk(_ title: String, fileName: String) -> Bool {
        let lowered = title.lowercased()
        if lowered == "untitled" || lowered.hasPrefix("microsoft word - ") || lowered.hasPrefix("microsoft powerpoint - ") {
            return true
        }
        // e.g. an english generator title on a japanese file name
        return title.allSatisfy(\.isASCII) && !fileName.allSatisfy(\.isASCII)
    }
}
