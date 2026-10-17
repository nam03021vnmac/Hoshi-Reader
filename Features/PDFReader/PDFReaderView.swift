//
//  PDFReaderView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PDFKit
import SwiftUI

struct PDFReaderView: View {
    @Environment(\.dismissReader) private var dismissReader
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(UserConfig.self) private var userConfig
    @State private var viewModel: PDFReaderViewModel
    @State private var focusMode = false
    @State private var confirmBookOCR = false
    @State private var topSafeArea: CGFloat
    @State private var bottomSafeArea: CGFloat
    
    init(book: BookMetadata) {
        _viewModel = State(initialValue: PDFReaderViewModel(book: book))
        _topSafeArea = State(initialValue: UIDevice.current.userInterfaceIdiom == .pad ? 35 : UIApplication.topSafeArea)
        _bottomSafeArea = State(initialValue: UIDevice.current.userInterfaceIdiom == .pad ? 20 : UIApplication.bottomSafeArea)
    }
    
    /// Height of the strip at the bottom of the screen where a tap shows the controls
    private static let controlsTapZoneHeight: CGFloat = 120

    private var readerBottomPadding: CGFloat {
        bottomSafeArea > 0 ? bottomSafeArea : max(topSafeArea, 25)
    }
    
    private var sepiaInverted: Bool {
        userConfig.theme == .sepia && userConfig.sepiaInvertInDark && systemColorScheme == .dark
    }
    
    private var readerBackgroundColor: Color {
        if sepiaInverted {
            return Color(red: 0.094, green: 0.082, blue: 0.047)
        }
        if userConfig.theme == .sepia || (userConfig.theme == .system && userConfig.systemLightSepia && systemColorScheme == .light) {
            return Color(red: 0.949, green: 0.886, blue: 0.788)
        }
        return userConfig.theme == .custom ? userConfig.customBackgroundColor : Color(.systemBackground)
    }
    
    private var readerTheme: ColorScheme {
        if userConfig.theme == .custom {
            return userConfig.uiTheme.colorScheme ?? systemColorScheme
        }
        if userConfig.theme == .sepia && userConfig.sepiaInvertInDark {
            return systemColorScheme
        }
        return userConfig.theme.colorScheme ?? systemColorScheme
    }
    
    private var infoStyle: AnyShapeStyle {
        userConfig.theme == .custom ? AnyShapeStyle(userConfig.customInfoColor) : AnyShapeStyle(.secondary)
    }
    
    private var pageString: String {
        "\(viewModel.pageIndex + 1) / \(viewModel.pageCount)"
    }
    
    private var statisticsString: String {
        var result: [String] = []
        if userConfig.readerShowReadingSpeed {
            result.append("\(viewModel.sessionStatistics.lastReadingSpeed.formatted(.number.grouping(.never))) / h")
        }
        if userConfig.readerShowReadingTime {
            result.append("\(Duration.seconds(viewModel.sessionStatistics.readingTime).formatted(.time(pattern: .hourMinute)))")
        }
        return result.joined(separator: " ")
    }
    
    private var ocrModelState: OCRModelStore.State {
        OCRModelStore.shared.state(for: viewModel.ocrPack)
    }
    
    /// Only taps at the bottom of the screen show the controls; anywhere else a tap just hides them.
    private func handleTapOutside(at point: CGPoint, screenHeight: CGFloat) {
        viewModel.clearSelection()
        guard viewModel.popups.isEmpty else {
            viewModel.closePopups()
            return
        }
        let inControlsZone = point.y >= screenHeight - Self.controlsTapZoneHeight
        guard inControlsZone || !focusMode else {
            return
        }
        withAnimation(.default.speed(2)) {
            focusMode.toggle()
        }
    }
    
    var body: some View {
        ZStack {
            readerBackgroundColor.ignoresSafeArea()
            
            if let document = viewModel.document {
                GeometryReader { geometry in
                    ZStack {
                        PDFKitView(
                            document: document,
                            initialPage: viewModel.pageIndex,
                            displayMode: userConfig.pdfDisplayMode,
                            rightToLeft: userConfig.pdfRightToLeft,
                            onPageChanged: { index in
                                // PDFView can repeat the current page while laying out, which would hide the controls right after a tap showed them
                                guard index != viewModel.pageIndex else {
                                    return
                                }
                                viewModel.pageChanged(to: index)
                                if !focusMode {
                                    withAnimation(.default.speed(2)) {
                                        focusMode = true
                                    }
                                }
                            },
                            onPageTap: { index, pagePoint, viewPoint in
                                Task {
                                    if await !viewModel.handlePageTap(pageIndex: index, point: pagePoint) {
                                        handleTapOutside(at: viewPoint, screenHeight: geometry.size.height)
                                    }
                                }
                            },
                            onTapOutside: { viewPoint in
                                handleTapOutside(at: viewPoint, screenHeight: geometry.size.height)
                            },
                            onViewportChanged: {
                                viewModel.viewportChanged()
                            },
                            onViewCreated: { pdfView, overlayProvider in
                                viewModel.pdfView = pdfView
                                viewModel.highlightProvider = overlayProvider
                            }
                        )
                        .id(PDFKitViewState(displayMode: userConfig.pdfDisplayMode, rightToLeft: userConfig.pdfRightToLeft))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        
                        ForEach($viewModel.popups) { $popup in
                            let popupId = popup.id
                            PopupView(
                                userConfig: userConfig,
                                isVisible: $popup.showPopup,
                                selectionData: popup.currentSelection,
                                lookupResults: popup.lookupResults,
                                dictionaryStyles: popup.dictionaryStyles,
                                screenSize: geometry.size,
                                isVertical: popup.isVertical,
                                isFullWidth: popup.isFullWidth,
                                coverURL: viewModel.coverURL,
                                documentTitle: viewModel.book.displayTitle,
                                clearSelection: popup.clearSelection,
                                onTextSelected: {
                                    if let index = viewModel.popups.firstIndex(where: { $0.id == popupId }) {
                                        viewModel.closeChildPopups(parent: index)
                                    }
                                    return viewModel.handleTextSelection($0, maxResults: userConfig.maxResults, scanLength: userConfig.scanLength, isVertical: false, isFullWidth: false)
                                },
                                onTapOutside: {
                                    if let index = viewModel.popups.firstIndex(where: { $0.id == popupId }) {
                                        viewModel.closeChildPopups(parent: index)
                                    }
                                },
                                onSwipeDismiss: {
                                    guard let index = viewModel.popups.firstIndex(where: { $0.id == popupId }) else {
                                        return
                                    }
                                    if index == 0 {
                                        viewModel.clearSelection()
                                        viewModel.closePopups()
                                    } else if viewModel.popups.indices.contains(index - 1) {
                                        viewModel.popups[index - 1].clearSelection.toggle()
                                        viewModel.closeChildPopups(parent: index - 1)
                                    }
                                }
                            )
                            .zIndex(Double(100 + (viewModel.popups.firstIndex(where: { $0.id == popupId }) ?? 0)))
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                // pages use the whole screen, the chrome floats on top
                .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Text("Couldn't open book")
                        .foregroundStyle(.secondary)
                    Button("Close") { dismissReader?() }
                }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let progress = viewModel.bookOCRProgress {
                    HStack(spacing: 10) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            .frame(width: 80)
                        Text("Recognizing pages \(progress.done) / \(progress.total)")
                            .font(.caption)
                            .monospacedDigit()
                        Button {
                            viewModel.cancelBookOCR()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .conditionalGlassEffect()
                }
                if viewModel.isLoadingPage {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Recognizing text…")
                            .font(.caption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .conditionalGlassEffect()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .foregroundStyle(infoStyle)
            .padding(.top, topSafeArea + 8)
            .animation(.default, value: viewModel.isLoadingPage)
        }
        .overlay(alignment: .bottom) {
            if userConfig.readerAlwaysShowProgress && viewModel.document != nil {
                Text(pageString)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(infoStyle)
                    .padding(.bottom, readerBottomPadding / 2 - 6)
                    .opacity(focusMode ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            HStack {
                Button {
                    viewModel.saveBookmark()
                    viewModel.stopTracking()
                    dismissReader?()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .conditionalGlassEffect()
                
                Spacer()
                
                if viewModel.document != nil {
                    HStack(spacing: 8) {
                        if userConfig.readerShowStatisticsToggle {
                            Button {
                                if viewModel.isTracking {
                                    viewModel.stopTracking()
                                } else {
                                    viewModel.startTracking()
                                }
                            } label: {
                                Image(systemName: viewModel.isTracking ? "timer" : "chart.bar.xaxis")
                                    .font(.system(size: 15))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            viewModel.activeSheet = .contents
                        } label: {
                            VStack(spacing: 2) {
                                if !statisticsString.isEmpty {
                                    Text(statisticsString)
                                }
                                Text(pageString)
                            }
                            .font(.caption)
                            .monospacedDigit()
                            .tracking(-0.4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(infoStyle)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .conditionalGlassEffect()
                    
                    Spacer()
                    
                    Menu {
                        Button {
                            viewModel.activeSheet = .statistics
                        } label: {
                            Label("Statistics", systemImage: "chart.bar.xaxis")
                        }
                        
                        if viewModel.ocrEnabled {
                            Section {
                                Button {
                                    viewModel.rerunOCR()
                                } label: {
                                    Label("Re-run OCR on This Page", systemImage: "arrow.clockwise")
                                }
                                .disabled(viewModel.isLoadingPage)
                                
                                Toggle(isOn: Binding(
                                    get: { viewModel.forceOCR },
                                    set: { viewModel.setForceOCR($0) }
                                )) {
                                    Label("Always Use OCR for This Book", systemImage: "text.viewfinder")
                                }
                                
                                Toggle(isOn: Binding(
                                    get: { viewModel.isManga },
                                    set: { viewModel.setManga($0) }
                                )) {
                                    Label("Use Manga Model for This Book", systemImage: "book.pages")
                                }
                                
                                if viewModel.bookOCRProgress != nil {
                                    Button(role: .destructive) {
                                        viewModel.cancelBookOCR()
                                    } label: {
                                        Label("Stop OCR", systemImage: "stop.circle")
                                    }
                                } else {
                                    Button {
                                        confirmBookOCR = true
                                    } label: {
                                        Label("OCR All Pages…", systemImage: "doc.text.viewfinder")
                                    }
                                }
                            }
                        }
                        
                        #if DEBUG
                        Toggle(isOn: $viewModel.showTextBoxes) {
                            Label("Show Text Boxes", systemImage: "rectangle.dashed")
                        }
                        #endif
                        
                        Button {
                            viewModel.activeSheet = .settings
                        } label: {
                            Label("PDF Settings", systemImage: "doc.richtext")
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 20))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .conditionalGlassEffect()
                } else {
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, bottomSafeArea > 0 ? bottomSafeArea : 8)
            .opacity(focusMode ? 0 : 1)
            .allowsHitTesting(!focusMode)
        }
        .sheet(item: $viewModel.activeSheet) { sheet in
            switch sheet {
            case .contents:
                PDFContentsSheet(viewModel: viewModel, readerTheme: readerTheme)
            case .settings:
                NavigationStack {
                    PDFSettingsView()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    viewModel.activeSheet = nil
                                } label: {
                                    Image(systemName: "xmark")
                                }
                            }
                        }
                }
                .presentationDetents([.large])
                .preferredColorScheme(readerTheme)
            case .statistics:
                PDFStatisticsSheet(viewModel: viewModel)
                    .preferredColorScheme(readerTheme)
            case .ocrModel:
                PDFOCRModelPrompt(pack: viewModel.ocrPack) {
                    viewModel.activeSheet = nil
                }
                .presentationDetents([.medium])
                .preferredColorScheme(readerTheme)
            }
        }
        .confirmationDialog("OCR All Pages", isPresented: $confirmBookOCR, titleVisibility: .visible) {
            Button("Start") {
                viewModel.startBookOCR()
            }
        } message: {
            Text("Recognizes text on every page without a text layer, so lookups are instant. This can take a while.")
        }
        .alert("OCR Failed", isPresented: Binding(
            get: { viewModel.ocrError != nil },
            set: { if !$0 { viewModel.ocrError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.ocrError ?? "")
        }
        .task(id: viewModel.isTracking) {
            guard viewModel.isTracking else {
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !viewModel.isPaused {
                    viewModel.updateStats()
                }
            }
        }
        .onChange(of: viewModel.activeSheet) { _, sheet in
            if sheet == nil {
                viewModel.resetTrackingBaseline()
                viewModel.isPaused = false
            } else {
                viewModel.isPaused = true
            }
        }
        .onChange(of: userConfig.pdfOCRMode) {
            viewModel.refreshOCR()
        }
        .onChange(of: ocrModelState) {
            viewModel.refreshOCR()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            viewModel.handleMemoryWarning()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // progress is on disk per page, so it resumes where it stopped
            viewModel.cancelBookOCR()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            viewModel.saveBookmark()
            viewModel.flushTextLayers()
            if viewModel.isTracking {
                viewModel.isPaused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard viewModel.isTracking, viewModel.activeSheet == nil else {
                return
            }
            viewModel.resetTrackingBaseline()
            viewModel.isPaused = false
        }
        .onDisappear {
            viewModel.saveBookmark()
            viewModel.close()
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(focusMode)
        .persistentSystemOverlays(focusMode ? .hidden : .automatic)
        .preferredColorScheme(readerTheme)
    }
}
