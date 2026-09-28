import SmolPDFCore
import SwiftUI

struct ProfileInspector: View {
    @Environment(AppModel.self) private var model

    private static let resolutions = [72, 96, 110, 150, 200, 300, 600]

    var body: some View {
        let profile = model.selectedProfile
        let binding = Binding<CompressionProfile>(
            get: { model.selectedProfile },
            set: { model.updateProfile($0) }
        )
        VStack(spacing: 0) {
            CompressionGauge()
                .padding(.top, 2)
                // Leave room for the dial's shadow, which the opaque form would otherwise cover.
                .padding(.bottom, 14)
            form(profile, binding)
        }
    }

    private func form(_ profile: CompressionProfile, _ binding: Binding<CompressionProfile>) -> some View {
        Form {
            Section {
                Picker("Profile", selection: Binding(
                    get: { model.selectedProfileID },
                    set: { model.selectedProfileID = $0 }
                )) {
                    ForEach(CompressionProfile.builtIns) { Text($0.name).tag($0.id) }
                    if !model.customProfiles.isEmpty {
                        Divider()
                        ForEach(model.customProfiles) { Text($0.name).tag($0.id) }
                    }
                }
                .disabled(model.isCompressing)
                if !profile.isBuiltIn {
                    TextField("Name", text: binding.name)
                }
            } footer: {
                HStack {
                    if profile.isBuiltIn {
                        Text("Built-in profiles can’t be changed.")
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Customize…") { model.duplicateSelectedProfile() }
                    } else {
                        Spacer()
                        Button("Delete Profile", role: .destructive) { model.deleteProfile(profile.id) }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(model.isCompressing)
            }

            Section("Images") {
                Toggle("Compress images", isOn: binding.compressImages)
                Group {
                    VStack(alignment: .leading) {
                        LabeledContent("Quality", value: Format.percent(profile.imageQuality))
                        // Round in the binding instead of passing `step:`, which draws a tick mark per step on macOS.
                        Slider(value: Binding(
                            get: { profile.imageQuality },
                            set: { binding.wrappedValue.imageQuality = ($0 * 20).rounded() / 20 }
                        ), in: 0.05...1) {
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
