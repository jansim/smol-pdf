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
                .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if model.items.isEmpty {
                    DropZoneView(isTargeted: isDropTargeted)
                } else if model.isBatch {
                    BatchView()
                        .safeAreaInset(edge: .bottom, spacing: 0) { BottomBar() }
                } else {
                    FilePairView()
                        .safeAreaInset(edge: .bottom, spacing: 0) { BottomBar() }
                }
            }
            // Reach under the toolbar, so its buttons float on the same background.
            .background(TranslucentBackground().ignoresSafeArea())
            .navigationSplitViewColumnWidth(min: 400, ideal: 560)
            .dropDestination(for: URL.self) { urls, _ in
                // Nothing can be added during a run.
                guard !model.isCompressing else { return false }
                model.add(urls)
                return true
            } isTargeted: { isDropTargeted = $0 && !model.isCompressing }
            .overlay {
                if isDropTargeted && !model.items.isEmpty {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            .toolbar {
                Button { model.openPanel() } label: {
                    Label("Open File", systemImage: "plus")
                }
                .help("Open PDF files or folders")
                // Without a title, this keeps the close button on the right.
                Spacer()
                Button { model.close() } label: {
                    Label("Close", systemImage: "xmark")
                }
                .help(model.isBatch ? "Close these files" : "Close the current file")
                .disabled(model.items.isEmpty || model.isCompressing)
            }
        }
        .inspector(isPresented: $showInspector) {
            ProfileInspector()
                .inspectorColumnWidth(min: 290, ideal: 300, max: 360)
                .toolbar {
                    Spacer()
                    Button { showInspector.toggle() } label: {
                        Label("Profile Settings", systemImage: "sidebar.right")
                    }
                    .help("Show or hide profile settings")
                }
        }
        .background(TitlelessWindow())
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
                Text("Drop PDF Files or Folders Here")
                    .font(.title2.weight(.semibold))
                Text("They’re compressed with the “\(model.selectedProfile.name)” profile.")
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
        .contentShape(Rectangle())
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
            if model.isCompressing {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: model.runProgress)
                        .frame(width: 220)
                    Text(progressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            Picker("Profile", selection: $model.selectedProfileID) {
                ForEach(CompressionProfile.builtIns) { Text(model.displayName(of: $0)).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.isCompressing)
            if model.isCompressing {
                Button(model.isCancelling ? "Cancelling…" : "Cancel") { model.cancel() }
                    .frame(minWidth: 90)
                    .disabled(model.isCancelling)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    model.compress()
                } label: {
                    Text(compressTitle)
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCompress)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var compressTitle: String {
        guard model.isBatch else { return model.current?.isFinished == true ? "Compress Again" : "Compress" }
        let count = model.compressibleCount
        let files = count == 1 ? "1 File" : "\(count) Files"
        return model.compressesAgain ? "Compress \(files) Again" : "Compress \(files)"
    }

    /// The time left once a run is projected to take a while, the percentage before.
    private var progressText: String {
        if let seconds = model.timeRemaining { return Format.timeRemaining(seconds) }
        return "Compressing… \(Format.percent(model.runProgress))"
    }
}

/// Hides the window title and lets the toolbar buttons float without a bar behind them.
struct TitlelessWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowObserver() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowObserver: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbar?.showsBaselineSeparator = false
        }
    }
}

/// The desktop showing through the window, like a sidebar.
struct TranslucentBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "About 40 seconds remaining", rounded so that it doesn't change every moment.
    static func timeRemaining(_ seconds: TimeInterval) -> String {
        let rounded = seconds < 60 ? max(5, (seconds / 5).rounded(.up) * 5) : (seconds / 60).rounded() * 60
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        formatter.includesApproximationPhrase = true
        formatter.includesTimeRemainingPhrase = true
        return formatter.string(from: rounded) ?? ""
    }
}
