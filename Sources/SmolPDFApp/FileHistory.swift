import QuickLookThumbnailing
import SmolPDFCore
import SwiftUI
import UniformTypeIdentifiers

/// A finished compression, remembered across launches.
struct HistoryEntry: Codable, Hashable, Identifiable {
    var id = UUID()
    var inputURL: URL
    var outputURL: URL
    var originalSize: Int64
    var compressedSize: Int64
    var keptOriginal: Bool
    /// Where the original went when it was replaced.
    var trashedURL: URL?
    var profileName: String
    var date: Date

    init(result: CompressionResult, profileName: String, date: Date = .now) {
        inputURL = result.inputURL
        outputURL = result.outputURL
        originalSize = result.originalSize
        compressedSize = result.compressedSize
        keptOriginal = result.keptOriginal
        trashedURL = result.trashedURL
        self.profileName = profileName
        self.date = date
    }

    var name: String { outputURL.lastPathComponent }

    var result: CompressionResult {
        CompressionResult(
            inputURL: inputURL, outputURL: outputURL, originalSize: originalSize,
            compressedSize: compressedSize, keptOriginal: keptOriginal, trashedURL: trashedURL
        )
    }

    var savedFraction: Double {
        originalSize > 0 ? Double(max(0, originalSize - compressedSize)) / Double(originalSize) : 0
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: outputURL.path) }
}

struct FileHistorySidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Selecting an entry shows it in the window.
        List(selection: Binding(get: { model.selectedHistoryID }, set: { model.showHistory($0) })) {
            Section("File History") {
                ForEach(model.history) { HistoryRow(entry: $0).tag($0.id) }
            }
        }
        .overlay {
            if model.history.isEmpty {
                ContentUnavailableView(
                    "No History Yet", systemImage: "clock",
                    description: Text("Compressed files will show up here.")
                )
            }
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            let entries = entries(ids)
            if !entries.isEmpty {
                Button("Open") { entries.forEach(open) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(entries.map(\.outputURL))
                }
                Divider()
                Button("Remove from History") { model.removeHistory(ids) }
            }
        } primaryAction: { ids in
            entries(ids).forEach(open)
        }
        .onDeleteCommand {
            if let id = model.selectedHistoryID { model.removeHistory([id]) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button("Clear History") { model.clearHistory() }
                    .disabled(model.history.isEmpty)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(8)
        }
    }

    private func entries(_ ids: Set<HistoryEntry.ID>) -> [HistoryEntry] {
        model.history.filter { ids.contains($0.id) }
    }

    private func open(_ entry: HistoryEntry) {
        NSWorkspace.shared.open(entry.outputURL)
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?

    private static let pdfIcon = NSWorkspace.shared.icon(for: .pdf)
    private static let thumbnailSize = CGSize(width: 28, height: 28)

    var body: some View {
        let exists = entry.fileExists
        HStack(spacing: 8) {
            Image(nsImage: thumbnail ?? Self.pdfIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(exists ? 1 : 0.45)
        .padding(.vertical, 2)
        .help(exists ? "\(entry.outputURL.path)\n\(entry.profileName) · \(entry.date.formatted())"
                     : "File no longer exists")
        .task(id: entry.outputURL) { await loadThumbnail(exists: exists) }
    }

    /// Renders the first page via Quick Look, which caches thumbnails and keeps the PDF icon for locked files.
    private func loadThumbnail(exists: Bool) async {
        guard exists else { thumbnail = nil; return }
        let request = QLThumbnailGenerator.Request(
            fileAt: entry.outputURL, size: Self.thumbnailSize, scale: displayScale, representationTypes: .thumbnail
        )
        thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }

    private var details: String {
        if entry.keptOriginal { return "\(Format.bytes(entry.originalSize)) · already optimal" }
        return "\(Format.bytes(entry.originalSize)) → \(Format.bytes(entry.compressedSize)) (−\(Format.percent(entry.savedFraction)))"
    }
}
