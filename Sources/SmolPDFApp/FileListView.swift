import SmolPDFCore
import SwiftUI

struct FileListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<PDFItem.ID>()

    var body: some View {
        List(selection: $selection) {
            ForEach(model.items) { item in
                FileRow(item: item)
                    .tag(item.id)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: PDFItem.ID.self) { ids in
            contextMenu(for: items(ids))
        } primaryAction: { ids in
            for item in items(ids) { open(item) }
        }
        .onDeleteCommand { model.remove(selection) }
    }

    private func items(_ ids: Set<PDFItem.ID>) -> [PDFItem] {
        model.items.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private func contextMenu(for items: [PDFItem]) -> some View {
        if !items.isEmpty {
            Button("Open") { items.forEach(open) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(items.map { $0.result?.outputURL ?? $0.url })
            }
            if items.count == 1, let item = items.first, let result = item.result, !result.keptOriginal,
               result.outputURL != result.inputURL {
                Button("Compare with Original") { model.compareItem = item }
            }
            let ready = items.filter { $0.status == .ready }
            if !ready.isEmpty {
                Divider()
                Button("Compress Selected") { model.compress(ready) }
                    .disabled(model.isCompressing)
            }
            Divider()
            Button("Remove from List") { model.remove(Set(items.map(\.id))) }
        }
    }

    private func open(_ item: PDFItem) {
        if item.status == .locked {
            model.unlockItem = item
        } else {
            NSWorkspace.shared.open(item.result?.outputURL ?? item.url)
        }
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    let item: PDFItem

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(image: item.thumbnail, locked: item.status == .locked)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            status
        }
        .padding(.vertical, 5)
    }

    private var details: String {
        var parts: [String] = []
        if item.pageCount > 0 { parts.append("\(item.pageCount) \(item.pageCount == 1 ? "page" : "pages")") }
        parts.append(Format.bytes(item.originalSize))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .ready:
            Text("Ready")
                .foregroundStyle(.secondary)
        case .locked:
            Button {
                model.unlockItem = item
            } label: {
                Label("Unlock…", systemImage: "lock.fill")
            }
        case .compressing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Compressing…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: 260, alignment: .trailing)
        case .done(let result):
            if result.keptOriginal {
                Label("Already optimal – original kept", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ResultView(item: item, result: result)
            }
        }
    }
}

struct ResultView: View {
    @Environment(AppModel.self) private var model
    let item: PDFItem
    let result: CompressionResult

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Text(Format.bytes(result.originalSize)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(Format.bytes(result.compressedSize)).fontWeight(.semibold)
                }
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                SavingsBar(fraction: result.savedFraction)
                    .frame(width: 110, height: 5)
            }
            Text("−" + Format.percent(result.savedFraction))
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.green.gradient))
                .fixedSize()
            HStack(spacing: 2) {
                if result.outputURL != result.inputURL {
                    Button { model.compareItem = item } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .help("Compare with original")
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([result.outputURL]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Show in Finder")
            }
            .buttonStyle(.borderless)
        }
    }
}

/// The remaining size as a filled bar; the saved part is left empty.
struct SavingsBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green)
                    .frame(width: max(3, geo.size.width * (1 - fraction)))
            }
        }
    }
}

struct Thumbnail: View {
    var image: NSImage?
    var locked = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.background)
                    .overlay {
                        Image(systemName: locked ? "lock.fill" : "doc.richtext")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 34, height: 44)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}
