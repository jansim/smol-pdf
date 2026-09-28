import AppKit
import SwiftUI

@main
struct SmolPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("smol-pdf", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 460)
        }
        .defaultSize(width: 980, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { model.openPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Compression") {
                Button("Compress") { model.compressAll() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isCompressing || model.items.isEmpty)
                Divider()
                Picker("Profile", selection: $model.selectedProfileID) {
                    ForEach(model.allProfiles) { Text($0.name).tag($0.id) }
                }
                Button("New Profile from Selected") { model.duplicateSelectedProfile() }
                Divider()
                Button("Remove Finished") { model.clearFinished() }
                    .keyboardShortcut("k")
                Button("Remove All") { model.clear() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
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
