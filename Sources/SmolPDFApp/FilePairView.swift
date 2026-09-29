import QuickLook
import SmolPDFCore
import SwiftUI
import UniformTypeIdentifiers

/// The file being worked on: its original next to the compressed result.
struct FilePairView: View {
    @Environment(AppModel.self) private var model
    /// The before or after file picked with a click; Space previews it.
    @State private var selectedFile: URL?
    @State private var quickLookURL: URL?
    /// The pair's unscaled size, to shrink it into a small window.
    @State private var pairSize = CGSize(width: FilePair.width, height: 240)
    /// Bumped when the app becomes active, so files trashed or deleted meanwhile are shown as such.
    @State private var filesCheckedAt = Date.now
    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            if let item = model.current {
                FilePair(item: item, selectedFile: selectedFile, selectFile: selectFile, preview: preview)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { pairSize = $0 }
                    // Shrink the pair in a small window rather than letting it set the window's minimum size.
                    .scaleEffect(scale(fitting: proxy.size))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .padding(24)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { selectedFile = nil }
        .onChange(of: model.current?.id) { selectedFile = nil }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.space) { togglePreview() }
        .onDeleteCommand { removeSelected() }
        .quickLookPreview($quickLookURL)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            filesCheckedAt = .now
        }
        .environment(\.filesCheckedAt, filesCheckedAt)
    }

    private func scale(fitting size: CGSize) -> CGFloat {
        let fit = min(size.width / pairSize.width, size.height / pairSize.height)
        return max(FilePair.minScale, min(1, fit))
    }

    private func selectFile(_ url: URL) {
        selectedFile = url
        isFocused = true
        if NSApp.currentEvent?.clickCount == 2, FileLocation(url) != .missing {
            NSWorkspace.shared.open(url)
        }
    }

    private func preview(_ url: URL) {
        quickLookURL = url
    }

    private func togglePreview() -> KeyPress.Result {
        if quickLookURL != nil {
            quickLookURL = nil
            return .handled
        }
        guard let selectedFile, FileLocation(selectedFile) != .missing else { return .ignored }
        quickLookURL = selectedFile
        return .handled
    }

    private func removeSelected() {
        guard selectedFile != nil else { return }
        model.close()
        selectedFile = nil
    }
}

extension VerticalAlignment {
    private enum TileCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    /// The middle of a file tile's box, so the arrow lines up with the boxes rather than the labels below.
    static let tileCenter = VerticalAlignment(TileCenter.self)
}

/// One file: the original on the left, the result (or its progress) on the right.
struct FilePair: View {
    private static let middleWidth: CGFloat = 130
    private static let spacing: CGFloat = 16
    /// The unscaled width of the pair, before it's measured.
    static var width: CGFloat { 2 * FileTile.width + middleWidth + 2 * spacing }
    /// How far the pair shrinks in a narrow window.
    static let minScale: CGFloat = 0.65

    @Environment(AppModel.self) private var model
    let item: PDFItem
    var selectedFile: URL?
    var selectFile: (URL) -> Void
    var preview: (URL) -> Void

    var body: some View {
        HStack(alignment: .tileCenter, spacing: Self.spacing) {
            let result = item.result
            tile(
                url: result?.originalURL ?? item.url, name: result?.inputURL.lastPathComponent ?? item.name,
                size: result?.originalSize ?? item.originalSize, thumbnail: item.thumbnail,
                locked: item.status == .locked
            )
            middle
                .frame(width: Self.middleWidth)
                .alignmentGuide(.tileCenter) { $0[VerticalAlignment.center] }
            if let result, !result.keptOriginal {
                tile(
                    url: result.outputURL, name: result.outputURL.lastPathComponent, size: result.compressedSize,
                    thumbnail: item.compressedThumbnail ?? item.thumbnail
                )
            } else {
                placeholder
            }
        }
        .fixedSize()
    }

    private func tile(url: URL, name: String, size: Int64, thumbnail: NSImage?, locked: Bool = false) -> some View {
        FileTile(
            url: url, name: name, size: size, thumbnail: thumbnail, locked: locked,
            isSelected: selectedFile == url, select: { selectFile(url) }, preview: { preview(url) },
            remove: { model.close() }
        )
    }

    /// The dashed box where the compressed file will appear.
    private var placeholder: some View {
        TileBox {
            switch item.status {
            case .compressing:
                ProgressView()
            case .done:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
            default:
                EmptyView()
            }
        }
        .alignmentGuide(.tileCenter) { $0[VerticalAlignment.center] }
        .frame(width: FileTile.width, alignment: .top)
    }

    @ViewBuilder private var middle: some View {
        switch item.status {
        case .done(let result) where result.keptOriginal:
            VStack(spacing: 8) {
                profileLabel
                caption("Already optimal", detail: "The original was kept.")
            }
        case .done(let result):
            VStack(spacing: 6) {
                profileLabel
                    .padding(.bottom, 4)
                Image(systemName: "arrow.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("−" + Format.percent(result.savedFraction))
                    .font(.largeTitle.weight(.bold).monospacedDigit())
                Text("\(Format.bytes(result.savedBytes)) saved")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .compressing:
            caption("Compressing…")
        case .locked:
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Button("Unlock…") { model.unlockItem = item }
            }
        case .failed(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ready:
            VStack(spacing: 6) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.quaternary)
                Text("Ready")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The profile the result was made with.
    @ViewBuilder private var profileLabel: some View {
        if let name = item.profileName {
            Label(name, systemImage: "gauge.with.dots.needle.50percent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Compressed with the “\(name)” profile")
        }
    }

    private func caption(_ title: String, detail: String? = nil) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }
}

/// Where a file is now, checked when shown.
enum FileLocation {
    case present, inTrash, missing

    init(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            self = .missing
        } else if url.standardizedFileURL.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) {
            self = .inTrash
        } else {
            self = .present
        }
    }
}

extension EnvironmentValues {
    @Entry var filesCheckedAt = Date.distantPast
}

/// A dashed box holding a file, like a drop well.
struct TileBox<Content: View>: View {
    static var size: CGFloat { 136 }
    var isSelected = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: Self.size, height: Self.size)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14)
                if isSelected {
                    shape.fill(Color.accentColor.opacity(0.15))
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                } else {
                    shape.strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// One file of a before/after pair. Select it and press Space to preview it, or drag it out like a file.
struct FileTile: View {
    static let width: CGFloat = 170

    @Environment(\.filesCheckedAt) private var filesCheckedAt
    let url: URL
    let name: String
    let size: Int64
    let thumbnail: NSImage?
    var locked = false
    let isSelected: Bool
    let select: () -> Void
    let preview: () -> Void
    let remove: () -> Void

    private static let pdfIcon = NSWorkspace.shared.icon(for: .pdf)

    var body: some View {
        // Read so the location is checked again when the app becomes active.
        let _ = filesCheckedAt
        let location = FileLocation(url)
        VStack(spacing: 8) {
            TileBox(isSelected: isSelected) { image(badge: location) }
                .alignmentGuide(.tileCenter) { $0[VerticalAlignment.center] }
                .onTapGesture(perform: select)
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            Text(name)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            Text(Format.bytes(size))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            switch location {
            case .present: EmptyView()
            case .inTrash:
                Text("In Trash").font(.callout.weight(.semibold)).foregroundStyle(.orange)
            case .missing:
                Text("Missing").font(.callout.weight(.semibold)).foregroundStyle(.red)
            }
        }
        .frame(width: Self.width, alignment: .top)
        .contextMenu {
            if location != .missing {
                Button("Quick Look") { preview() }
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
            }
            Button("Close", action: remove)
        }
        .help(location == .missing ? "\(url.path)\nThe file no longer exists." : url.path)
    }

    private func image(badge location: FileLocation) -> some View {
        document
            .opacity(location == .missing ? 0.4 : 1)
            .overlay(alignment: .bottomTrailing) {
                switch location {
                case .present: EmptyView()
                case .inTrash: LocationBadge(systemImage: "trash.fill", color: .orange)
                case .missing: LocationBadge(systemImage: "questionmark", color: .red)
                }
            }
    }

    /// The first page, or a PDF icon when there is none.
    @ViewBuilder private var document: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 88, maxHeight: 108)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        } else {
            Image(nsImage: Self.pdfIcon)
                .resizable()
                .frame(width: 88, height: 88)
                .overlay(alignment: .bottomTrailing) {
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }
}

/// A round badge overlapping the corner of a thumbnail, e.g. for a file in the Trash.
struct LocationBadge: View {
    var systemImage: String
    var color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(color.gradient))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .offset(x: 12, y: 6)
    }
}
