import SmolPDFCore
import SwiftUI

extension CompressionProfile {
    var symbolName: String {
        switch id {
        case CompressionProfile.lossless.id: "checkmark.seal"
        case CompressionProfile.low.id: "gauge.with.dots.needle.33percent"
        case CompressionProfile.medium.id: "gauge.with.dots.needle.50percent"
        case CompressionProfile.high.id: "gauge.with.dots.needle.67percent"
        case CompressionProfile.maximum.id: "gauge.with.dots.needle.100percent"
        default: "slider.horizontal.3"
        }
    }
}

struct ProfileSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<UUID?>(
            get: { model.selectedProfileID },
            set: { if let id = $0 { model.selectedProfileID = id } }
        )
        List(selection: selection) {
            Section("Profiles") {
                ForEach(CompressionProfile.builtIns) { ProfileRow(profile: $0).tag($0.id) }
            }
            if !model.customProfiles.isEmpty {
                Section("Custom") {
                    ForEach(model.customProfiles) { profile in
                        ProfileRow(profile: profile)
                            .tag(profile.id)
                            .contextMenu {
                                Button("Delete Profile", role: .destructive) { model.deleteProfile(profile.id) }
                            }
                    }
                }
            }
        }
        .disabled(model.isCompressing)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Button { model.duplicateSelectedProfile() } label: {
                    Image(systemName: "plus").frame(width: 20, height: 20)
                }
                .help("New profile based on the selected one")
                Button { model.deleteProfile(model.selectedProfileID) } label: {
                    Image(systemName: "minus").frame(width: 20, height: 20)
                }
                .help("Delete the selected custom profile")
                .disabled(model.selectedProfile.isBuiltIn)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }
}

struct ProfileRow: View {
    let profile: CompressionProfile

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                Text(profile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: profile.symbolName)
        }
        .padding(.vertical, 2)
    }
}

struct ProfileInspector: View {
    @Environment(AppModel.self) private var model

    private static let resolutions = [72, 96, 110, 150, 200, 300, 600]

    var body: some View {
        let profile = model.selectedProfile
        let binding = Binding<CompressionProfile>(
            get: { model.selectedProfile },
            set: { model.updateProfile($0) }
        )
        Form {
            Section {
                if profile.isBuiltIn {
                    LabeledContent("Profile", value: profile.name)
                } else {
                    TextField("Name", text: binding.name)
                }
            } footer: {
                if profile.isBuiltIn {
                    HStack {
                        Text("Built-in profiles can’t be changed.")
                        Spacer()
                        Button("Customize…") { model.duplicateSelectedProfile() }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Images") {
                Toggle("Compress images", isOn: binding.compressImages)
                Group {
                    VStack(alignment: .leading) {
                        LabeledContent("Quality", value: Format.percent(profile.imageQuality))
                        Slider(value: binding.imageQuality, in: 0.05...1, step: 0.05) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "tortoise")
                        } maximumValueLabel: {
                            Image(systemName: "sparkles")
                        }
                        .labelsHidden()
                    }
                    Toggle("Limit resolution", isOn: Binding(
                        get: { profile.maxResolution != nil },
                        set: { binding.wrappedValue.maxResolution = $0 ? 150 : nil }
                    ))
                    if let dpi = profile.maxResolution {
                        Picker("Maximum", selection: Binding(
                            get: { dpi },
                            set: { binding.wrappedValue.maxResolution = $0 }
                        )) {
                            ForEach(Set(Self.resolutions + [dpi]).sorted(), id: \.self) { Text("\($0) dpi").tag($0) }
                        }
                    }
                }
                .disabled(!profile.compressImages)
            }
            .disabled(profile.isBuiltIn || model.isCompressing)

            Section("Document") {
                Toggle("Convert to grayscale", isOn: binding.grayscale)
                Toggle("Remove metadata", isOn: binding.removeMetadata)
                Toggle("Remove annotations & form fields", isOn: binding.removeAnnotations)
                Toggle("Remove bookmarks", isOn: binding.removeBookmarks)
            }
            .disabled(profile.isBuiltIn || model.isCompressing)
        }
        .formStyle(.grouped)
    }
}
