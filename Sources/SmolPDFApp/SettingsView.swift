import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Save compressed files") {
                Picker("Location", selection: $settings.destination) {
                    ForEach(AppSettings.Destination.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)

                switch settings.destination {
                case .sameFolder:
                    TextField("File name suffix", text: $settings.suffix, prompt: Text("-compressed"))
                case .folder:
                    LabeledContent("Folder") {
                        HStack {
                            Text(settings.outputFolder?.path(percentEncoded: false) ?? "None")
                                .lineLimit(1)
                                .truncationMode(.head)
                                .foregroundStyle(.secondary)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                case .replace:
                    Label("Originals are moved to the Trash.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Behavior") {
                Toggle("Keep the original when compression doesn’t make it smaller", isOn: $settings.keepOriginalIfLarger)
                Toggle("Compress files as soon as they are added", isOn: $settings.compressOnDrop)
                Toggle("Show compressed files in Finder when done", isOn: $settings.revealWhenDone)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { model.settings.outputFolder = panel.url }
    }
}
