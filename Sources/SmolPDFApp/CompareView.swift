import PDFKit
import SmolPDFCore
import SwiftUI

/// Side-by-side preview of the original and the compressed file, scrolled and zoomed in sync.
struct CompareView: View {
    @Environment(\.dismiss) private var dismiss
    let item: PDFItem

    var body: some View {
        VStack(spacing: 0) {
            if let result = item.result {
                HStack(spacing: 0) {
                    header("Original", size: result.originalSize)
                    Divider()
                    header("Compressed", size: result.compressedSize, saved: result.savedFraction)
                }
                .frame(height: 44)
                Divider()
                SyncedPDFViews(left: result.inputURL, right: result.outputURL, password: item.password)
            }
            Divider()
            HStack {
                Text(item.name).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    if let url = item.result?.outputURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 760)
    }

    private func header(_ title: String, size: Int64, saved: Double? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Text(Format.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
            if let saved {
                Text("−" + Format.percent(saved))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.green))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SyncedPDFViews: NSViewRepresentable {
    let left: URL
    let right: URL
    let password: String?

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        for url in [left, right] {
            let view = PDFView()
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            view.backgroundColor = .underPageBackgroundColor
            let doc = PDFDocument(url: url)
            if let password, doc?.isLocked == true { doc?.unlock(withPassword: password) }
            view.document = doc
            split.addArrangedSubview(view)
        }
        context.coordinator.attach(split.arrangedSubviews.compactMap { $0 as? PDFView })
        return split
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        private var views: [PDFView] = []
        private var isSyncing = false

        func attach(_ views: [PDFView]) {
            self.views = views
            for view in views {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(scaleChanged(_:)), name: .PDFViewScaleChanged, object: view
                )
            }
            // Scroll views only exist once the PDF views are in a window.
            DispatchQueue.main.async { [weak self] in self?.observeScrolling() }
        }

        private func observeScrolling() {
            for view in views {
                guard let clip = scrollView(in: view)?.contentView else { continue }
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: clip
                )
            }
        }

        @objc private func scaleChanged(_ note: Notification) {
            guard !isSyncing, let source = note.object as? PDFView else { return }
            isSyncing = true
            for view in views where view !== source {
                view.autoScales = false
                view.scaleFactor = source.scaleFactor
            }
            isSyncing = false
        }

        @objc private func scrolled(_ note: Notification) {
            guard !isSyncing, let clip = note.object as? NSClipView else { return }
            isSyncing = true
            for view in views {
                guard let other = scrollView(in: view)?.contentView, other !== clip else { continue }
                other.scroll(to: clip.bounds.origin)
                other.enclosingScrollView?.reflectScrolledClipView(other)
            }
            isSyncing = false
        }

        private func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for sub in view.subviews {
                if let found = scrollView(in: sub) { return found }
            }
            return nil
        }
    }
}
