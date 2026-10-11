//
//  PDFKitView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit
import SwiftUI

struct PDFKitViewState: Hashable {
    var displayMode: PDFDisplayMode
    var rightToLeft: Bool
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let initialPage: Int
    let displayMode: PDFDisplayMode
    let rightToLeft: Bool
    let onPageChanged: (Int) -> Void
    let onTap: () -> Void
    let onViewCreated: (PDFView) -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.backgroundColor = .clear
        pdfView.autoScales = true
        
        switch displayMode {
        case .paged:
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .horizontal
            pdfView.usePageViewController(true, withViewOptions: nil)
        case .continuous:
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
        }
        pdfView.displaysRTL = rightToLeft
        pdfView.document = document
        
        if let page = document.page(at: initialPage) {
            pdfView.go(to: page)
        }
        
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        pdfView.addGestureRecognizer(tap)
        
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        
        let coordinator = context.coordinator
        coordinator.pdfView = pdfView
        coordinator.restoringPage = initialPage
        // PDFView can report its default page while laying out; ignore that until the restore settles
        DispatchQueue.main.async {
            if let page = pdfView.document?.page(at: initialPage) {
                pdfView.go(to: page)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            coordinator.restoringPage = nil
        }
        onViewCreated(pdfView)
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.parent = self
    }
    
    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
    
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView
        weak var pdfView: PDFView?
        var restoringPage: Int?
        
        init(_ parent: PDFKitView) {
            self.parent = parent
        }
        
        @objc func handleTap() {
            parent.onTap()
        }
        
        @objc func pageChanged() {
            guard let pdfView, let document = pdfView.document, let page = pdfView.currentPage else {
                return
            }
            let index = document.index(for: page)
            guard index != NSNotFound else {
                return
            }
            if let target = restoringPage {
                if index == target {
                    restoringPage = nil
                }
                return
            }
            parent.onPageChanged(index)
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
