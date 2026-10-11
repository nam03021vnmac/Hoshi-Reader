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
    @State private var topSafeArea: CGFloat
    @State private var bottomSafeArea: CGFloat
    
    init(book: BookMetadata) {
        _viewModel = State(initialValue: PDFReaderViewModel(book: book))
        _topSafeArea = State(initialValue: UIDevice.current.userInterfaceIdiom == .pad ? 35 : UIApplication.topSafeArea)
        _bottomSafeArea = State(initialValue: UIDevice.current.userInterfaceIdiom == .pad ? 20 : UIApplication.bottomSafeArea)
    }
    
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
    
    var body: some View {
        ZStack {
            readerBackgroundColor.ignoresSafeArea()
            
            if let document = viewModel.document {
                PDFKitView(
                    document: document,
                    initialPage: viewModel.pageIndex,
                    displayMode: userConfig.pdfDisplayMode,
                    rightToLeft: userConfig.pdfRightToLeft,
                    onPageChanged: { index in
                        viewModel.pageChanged(to: index)
                        if !focusMode {
                            withAnimation(.default.speed(2)) {
                                focusMode = true
                            }
                        }
                    },
                    onTap: {
                        withAnimation(.default.speed(2)) {
                            focusMode.toggle()
                        }
                    },
                    onViewCreated: { viewModel.pdfView = $0 }
                )
                .id(PDFKitViewState(displayMode: userConfig.pdfDisplayMode, rightToLeft: userConfig.pdfRightToLeft))
                .padding(.top, topSafeArea)
                .padding(.bottom, readerBottomPadding)
            } else {
                VStack(spacing: 16) {
                    Text("Couldn't open book")
                        .foregroundStyle(.secondary)
                    Button("Close") { dismissReader?() }
                }
            }
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
                    Text(pageString)
                        .font(.caption)
                        .monospacedDigit()
                        .tracking(-0.4)
                        .foregroundStyle(infoStyle)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .conditionalGlassEffect()
                    
                    Spacer()
                    
                    Menu {
                        Button {
                            viewModel.activeSheet = .contents
                        } label: {
                            Label("Contents", systemImage: "list.bullet")
                        }
                        
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
                .presentationDetents([.medium])
                .preferredColorScheme(readerTheme)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            viewModel.saveBookmark()
        }
        .onDisappear {
            viewModel.saveBookmark()
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(focusMode)
        .persistentSystemOverlays(focusMode ? .hidden : .automatic)
        .preferredColorScheme(readerTheme)
    }
}
