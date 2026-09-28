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
                if model.current == nil {
                    DropZoneView(isTargeted: isDropTargeted)
                } else {
                    FilePairView()
                        .safeAreaInset(edge: .bottom, spacing: 0) { BottomBar() }
                }
            }
            // Reach under the toolbar, so its buttons float on the same background.
            .background(TranslucentBackground().ignoresSafeArea())
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted && model.current != nil {
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
                .help("Open a PDF file")
                // Without a title, this keeps the close button on the right.
                Spacer()
                Button { model.close() } label: {
                    Label("Close File", systemImage: "xmark")
                }
                .help("Close the current file")
                .disabled(model.current == nil || model.isCompressing)
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
                Text("Drop a PDF File Here")
                    .font(.title2.weight(.semibold))
                Text("It’s compressed with the “\(model.selectedProfile.name)” profile.")
                    .foregroundStyle(.secondary)
            }
            Button("Choose File…") { model.openPanel() }
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
            Spacer()
            Picker("Profile", selection: $model.selectedProfileID) {
                ForEach(model.allProfiles) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.isCompressing)
            Button {
                model.compress()
            } label: {
                if model.isCompressing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Compressing…")
                    }
                } else {
                    Text(model.current?.isFinished == true ? "Compress Again" : "Compress")
                        .frame(minWidth: 90)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canCompress)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
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
}
