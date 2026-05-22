//
//  CaptureKVMApp.swift
//  CaptureKVM
//
//  Created by Aaron Bartrim on 5/21/26.
//

import SwiftUI

@main
struct CaptureKVMApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("CaptureKVM Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: [.command])
            }
        }

        Window("CaptureKVM Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 800)

        Settings {
            SettingsView(model: model)
        }
    }
}
