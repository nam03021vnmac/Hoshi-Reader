//
//  SasayakiSettingsTab.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct SasayakiSettingsTab: View {
    @Environment(UserConfig.self) private var userConfig
    var player: SasayakiPlayer
    
    var body: some View {
        @Bindable var userConfig = userConfig
        Form {
            Section {
                VStack {
                    HStack {
                        Text("Delay")
                        Spacer()
                        Text(String(format: "%+.2fs", player.delay))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                    SteppedSlider(value: Bindable(player).delay, in: -4...4, step: 0.05)
                }
                VStack {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text(String(format: "%.2fx", player.rate))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                    SteppedSlider(value: Bindable(player).rate, in: 0.5...3, step: 0.05)
                }
            }
            
            Section("Reader Controls") {
                Toggle("Show Sasayaki Toggle", isOn: $userConfig.readerShowSasayakiToggle)
                Toggle("Show Control Bar", isOn: $userConfig.sasayakiShowControlBar)
                if userConfig.sasayakiShowControlBar {
                    Toggle("Always Show Control Bar", isOn: $userConfig.sasayakiAlwaysShowControlBar)
                    HStack {
                        Text("Control Bar Side")
                        Spacer()
                        Picker("", selection: $userConfig.sasayakiControlBarSide) {
                            Text("Left").tag(SasayakiControlBarSide.left)
                            Text("Right").tag(SasayakiControlBarSide.right)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
            }
            
            Section("Playback") {
                Toggle("Auto-Scroll", isOn: $userConfig.sasayakiAutoScroll)
                Toggle("Auto-Pause on Lookup", isOn: $userConfig.sasayakiAutoPause)
                Toggle(SasayakiSettingsView.doubleTapSeekTitle, isOn: $userConfig.sasayakiDoubleTapSeek)
                Toggle("Pause on Images", isOn: $userConfig.sasayakiImagePause)
                if userConfig.sasayakiImagePause {
                    HStack {
                        Text("Pause Duration")
                        Spacer()
                        Text("\(Int(userConfig.sasayakiImagePauseDuration))s")
                            .fontWeight(.semibold)
                        Stepper("", value: $userConfig.sasayakiImagePauseDuration, in: 1...30, step: 1)
                            .labelsHidden()
                    }
                }
            }
            
            Section("Light Theme") {
                ColorPicker("Text Color", selection: $userConfig.sasayakiTextColor)
                ColorPicker("Background Color", selection: $userConfig.sasayakiBackgroundColor)
            }
            
            Section("Dark Theme") {
                ColorPicker("Text Color", selection: $userConfig.sasayakiDarkTextColor)
                ColorPicker("Background Color", selection: $userConfig.sasayakiDarkBackgroundColor)
            }
        }
        .formStyle(.grouped)
    }
}
