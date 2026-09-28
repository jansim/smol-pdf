import SmolPDFCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            FileHistorySidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if model.items.isEmpty {
                    DropZoneView(isTargeted: isDropTargeted)
                } else {
                    FileListView()
                    Divider()
                    BottomBar()
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted && !model.items.isEmpty {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("smol-pdf")
            .navigationSubtitle(model.selectedProfile.name)
            .toolbar {
                ToolbarItemGroup {
                    Button { model.openPanel() } label: {
                        Label("Add Files", systemImage: "plus")
                    }
                    .help("Add PDF files or folders")
                    Button { model.clear() } label: {
                        Label("Clear List", systemImage: "trash")
                    }
                    .help("Remove all files from the list")
                    .disabled(model.items.isEmpty)
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            ProfileInspector()
                .inspectorColumnWidth(min: 260, ideal: 280, max: 340)
                .toolbar {
                    Spacer()
                    Button { showInspector.toggle() } label: {
                        Label("Profile Settings", systemImage: "sidebar.right")
                    }
                    .help("Show or hide profile settings")
                }
        }
        .sheet(item: $model.unlockItem) { PasswordSheet(item: $0) }
        .sheet(item: $model.compareItem) { CompareView(item: $0) }
    }
}

// MARK: - Empty state

struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    var isTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.right.and.arrow.up.left.circle.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: isTargeted)
            VStack(spacing: 6) {
                Text("Drop PDF Files Here")
                    .font(.title2.weight(.semibold))
                Text("Files and folders are compressed with the “\(model.selectedProfile.name)” profile.")
                    .foregroundStyle(.secondary)
            }
            Button("Choose Files…") { model.openPanel() }
                .controlSize(.large)
            Text(model.settings.destinationSummary)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
                )
                .padding(20)
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            summary
            Spacer()
            Picker("Profile", selection: $model.selectedProfileID) {
                ForEach(model.allProfiles) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.isCompressing)
            Button {
                model.compressAll()
            } label: {
                if model.isCompressing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Compressing…")
                    }
                } else {
                    Text(model.pendingItems.isEmpty ? "Compress Again" : "Compress")
                        .frame(minWidth: 90)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isCompressing)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder private var summary: some View {
        let results = model.finishedResults
        VStack(alignment: .leading, spacing: 2) {
            Text("\(model.items.count) \(model.items.count == 1 ? "file" : "files") · \(Format.bytes(model.totalOriginal))")
                .font(.callout)
            if !results.isEmpty {
                let before = results.reduce(0) { $0 + $1.originalSize }
                let after = results.reduce(0) { $0 + $1.compressedSize }
                let saved = before - after
                Text("Saved \(Format.bytes(saved)) (\(Format.percent(before > 0 ? Double(saved) / Double(before) : 0)))")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text(model.settings.destinationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
