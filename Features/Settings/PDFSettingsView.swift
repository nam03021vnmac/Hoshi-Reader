//
//  PDFSettingsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct PDFSettingsView: View {
    @Environment(UserConfig.self) private var userConfig
    
    var body: some View {
        @Bindable var userConfig = userConfig
        List {
            Section("Display") {
                Picker("Page Mode", selection: $userConfig.pdfDisplayMode) {
                    Text("Paged").tag(PDFDisplayMode.paged)
                    Text("Continuous").tag(PDFDisplayMode.continuous)
                }
                
                Toggle("Right-to-Left Pages", isOn: $userConfig.pdfRightToLeft)
            }
        }
        .navigationTitle("PDF")
    }
}
