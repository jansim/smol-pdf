import AppKit
import SmolPDFCore
import SwiftUI

@main
struct SmolPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("smol-pdf", id: "main") {
            ContentView()
                .environment(model)
                .frame(minHeight: 330)
        }
        .defaultSize(width: 1130, height: 640)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Compression") {
                Button("Compress") { model.compress() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canCompress)
                Divider()
                Picker("Profile", selection: $model.selectedProfileID) {
                    ForEach(CompressionProfile.builtIns) { Text(model.displayName(of: $0)).tag($0.id) }
                }
                Button("Reset Profile") { model.resetProfile(model.selectedProfileID) }
                    .disabled(!model.isCustomized(model.selectedProfileID) || model.isCompressing)
                Divider()
                Button("Close File") { model.close() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.current == nil || model.isCompressing)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched from `swift run` rather than as a bundled app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Files dropped onto the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
