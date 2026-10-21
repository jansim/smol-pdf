import AppKit
import Observation
import PDFKit
import SmolPDFCore

@Observable
@MainActor
final class PDFItem: Identifiable {
    enum Status: Equatable {
        case ready
        case locked
        /// Queued in a run that has started.
        case waiting
        case compressing
        case done(CompressionResult)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var originalSize: Int64
    var pageCount = 0
    var thumbnail: NSImage?
    /// First page of the compressed file, once there is one.
    var compressedThumbnail: NSImage?
    var status: Status = .ready
    /// Fraction done while compressing.
    var progress = 0.0
    var password: String?
    /// The profile the current result was made with.
    var profileName: String?

    init(url: URL) {
        self.url = url
        self.originalSize = PDFCompressor.fileSize(url)
    }

    /// A file compressed earlier, reopened from the history.
    init(entry: HistoryEntry) {
        url = entry.inputURL
        originalSize = entry.originalSize
        status = .done(entry.result)
        profileName = entry.profileName
    }

    var name: String { url.lastPathComponent }

    var result: CompressionResult? {
        if case .done(let result) = status { return result }
        return nil
    }

    var isFinished: Bool {
        switch status {
        case .done, .failed: true
        default: false
        }
    }
}

@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()

    /// The files shown in the window.
    var items: [PDFItem] = []
    /// Whether they were added together and are shown as a list, rather than one file's before and after.
    private(set) var isBatch = false
    /// The file shown in the window, when it's just one.
    var current: PDFItem? { isBatch ? nil : items.first }
    /// The history entry of the current file, highlighted in the sidebar.
    var selectedHistoryID: HistoryEntry.ID?
    /// User changes to built-in profiles, keyed by profile ID. Kept until the profile is reset.
    var profileOverrides: [UUID: CompressionProfile] = [:] { didSet { saveProfiles() } }
    /// Finished compressions, newest first. Persists across launches.
    var history: [HistoryEntry] = [] { didSet { saveHistory() } }
    var selectedProfileID: UUID = CompressionProfile.medium.id {
        didSet { UserDefaults.standard.set(selectedProfileID.uuidString, forKey: Keys.selectedProfile) }
    }
    var isCompressing = false
    var isCancelling = false
    /// How far the current run is, from 0 to 1.
    private(set) var runProgress = 0.0
    /// Seconds the current run has left, when it's projected to take long enough to be worth showing.
    private(set) var timeRemaining: TimeInterval?
    /// Item whose password is being asked for.
    var unlockItem: PDFItem?
    /// Item shown in the before/after comparison.
    var compareItem: PDFItem?

    let settings = AppSettings()

    private var runTask: Task<Void, Never>?
    private var runItems: [PDFItem] = []
    private var runEstimate = TimeEstimate()

    private enum Keys {
        static let profiles = "profileOverrides"
        static let selectedProfile = "selectedProfile"
        static let history = "history"
    }

    private static let historyLimit = 200
    /// Files compressed at once. Each uses all cores for its images, but files with few images mostly
    /// use one, so a few at once keep the cores busy.
    private static let concurrentFiles = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 2))

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.profiles),
           let profiles = try? JSONDecoder().decode([CompressionProfile].self, from: data) {
            let ids = Set(CompressionProfile.builtIns.map(\.id))
            profileOverrides = Dictionary(profiles.filter { ids.contains($0.id) }.map { ($0.id, $0) }) { a, _ in a }
        }
        if let data = UserDefaults.standard.data(forKey: Keys.history),
           let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = entries
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.selectedProfile),
           let id = UUID(uuidString: raw), CompressionProfile.builtIns.contains(where: { $0.id == id }) {
            selectedProfileID = id
        }
    }

    // MARK: Profiles

    /// The selected built-in profile, with the user's changes to it applied.
    var selectedProfile: CompressionProfile {
        profileOverrides[selectedProfileID]
            ?? CompressionProfile.builtIns.first { $0.id == selectedProfileID }
            ?? .medium
    }

    func isCustomized(_ id: UUID) -> Bool {
        profileOverrides[id] != nil
    }

    /// The profile's name, marked when the user changed its settings.
    func displayName(of profile: CompressionProfile) -> String {
        isCustomized(profile.id) ? "\(profile.name) (customized)" : profile.name
    }

    func updateProfile(_ profile: CompressionProfile) {
        guard let builtIn = CompressionProfile.builtIns.first(where: { $0.id == profile.id }) else { return }
        profileOverrides[profile.id] = profile == builtIn ? nil : profile
    }

    func resetProfile(_ id: UUID) {
        profileOverrides[id] = nil
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(Array(profileOverrides.values)) {
            UserDefaults.standard.set(data, forKey: Keys.profiles)
        }
    }

    // MARK: History

    func removeHistory(_ ids: Set<HistoryEntry.ID>) {
        history.removeAll { ids.contains($0.id) }
        if let id = selectedHistoryID, ids.contains(id) { selectedHistoryID = nil }
    }

    func clearHistory() {
        history.removeAll()
        selectedHistoryID = nil
    }

    /// Shows a file from the history in the window.
    func showHistory(_ id: HistoryEntry.ID?) {
        guard !isCompressing else { return }
        selectedHistoryID = id
        guard let id, let entry = history.first(where: { $0.id == id }) else { return }
        let item = PDFItem(entry: entry)
        items = [item]
        isBatch = false
        loadThumbnail(for: item, from: entry.result.originalURL)
        if !entry.keptOriginal { loadCompressedThumbnail(for: item, from: entry.outputURL) }
    }

    private func record(_ result: CompressionResult, profileName: String) -> HistoryEntry {
        let entry = HistoryEntry(result: result, profileName: profileName)
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        return entry
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Keys.history)
        }
    }

    // MARK: Files

    /// Opens the PDFs among `urls`, including those in folders, replacing what was shown. Several files are
    /// shown as a list.
    func add(_ urls: [URL]) {
        guard !isCompressing else { return }
        let files = PDFFinder.pdfs(in: urls)
        guard !files.isEmpty else { return }
        items = files.map(PDFItem.init(url:))
        isBatch = files.count > 1
        selectedHistoryID = nil
        for item in items { loadDetails(for: item, thumbnail: !isBatch) }
        if settings.compressOnDrop { compress() }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose PDF files or folders to compress"
        panel.prompt = "Open"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func close() {
        guard !isCompressing else { return }
        items = []
        isBatch = false
        selectedHistoryID = nil
    }

    /// Takes one file out of the list.
    func remove(_ item: PDFItem) {
        guard !isCompressing else { return }
        items.removeAll { $0 === item }
        if items.isEmpty { close() }
    }

    private func loadDetails(for item: PDFItem, thumbnail: Bool) {
        let url = item.url
        Task.detached(priority: .userInitiated) {
            let doc = PDFDocument(url: url)
            let opened = doc != nil
            let locked = doc?.isLocked ?? false
            let pages = doc?.pageCount ?? 0
            let thumb = thumbnail && !locked ? doc?.page(at: 0)?.thumbnail(of: Self.thumbnailSize, for: .cropBox) : nil
            await MainActor.run {
                item.pageCount = pages
                if thumbnail { item.thumbnail = thumb }
                guard item.status == .ready else { return }
                if !opened {
                    item.status = .failed(CompressionError.cannotOpen.localizedDescription)
                } else if locked {
                    item.status = .locked
                }
            }
        }
    }

    nonisolated private static let thumbnailSize = CGSize(width: 200, height: 260)

    nonisolated private static func thumbnail(of url: URL, password: String?) -> NSImage? {
        let doc = PDFDocument(url: url)
        if let password, doc?.isLocked == true { doc?.unlock(withPassword: password) }
        return doc?.page(at: 0)?.thumbnail(of: thumbnailSize, for: .cropBox)
    }

    private func loadThumbnail(for item: PDFItem, from url: URL) {
        let password = item.password
        Task.detached(priority: .userInitiated) {
            let thumb = Self.thumbnail(of: url, password: password)
            await MainActor.run { item.thumbnail = thumb }
        }
    }

    private func loadCompressedThumbnail(for item: PDFItem, from url: URL) {
        let password = item.password
        Task.detached(priority: .userInitiated) {
            let thumb = Self.thumbnail(of: url, password: password)
            await MainActor.run { item.compressedThumbnail = thumb }
        }
    }

    func unlock(_ item: PDFItem, password: String) -> Bool {
        guard let doc = PDFDocument(url: item.url), doc.unlock(withPassword: password) else { return false }
        item.password = password
        item.pageCount = doc.pageCount
        if !isBatch { item.thumbnail = doc.page(at: 0)?.thumbnail(of: Self.thumbnailSize, for: .cropBox) }
        item.status = .ready
        return true
    }

    // MARK: Compression

    /// What a run compresses with, fixed when it starts.
    private struct RunSettings: Sendable {
        var profile: CompressionProfile
        var profileName: String
        var location: OutputLocation
        var keepOriginal: Bool
    }

    var canCompress: Bool {
        !isCompressing && items.contains { $0.status == .ready || $0.isFinished }
    }

    /// Files a run would compress: those not compressed yet, and again those that were (e.g. with another
    /// profile). Locked files wait to be unlocked.
    private var compressible: [PDFItem] {
        items.filter { $0.status == .ready || $0.isFinished }
    }

    /// The number of files the Compress button compresses.
    var compressibleCount: Int { compressible.count }

    func compress() {
        guard canCompress else { return }
        let targets = compressible
        for item in targets {
            if item.isFinished {
                // After replacing the original, the item's file is now the compressed one.
                if item.result?.outputURL == item.url, let thumbnail = item.compressedThumbnail {
                    item.thumbnail = thumbnail
                }
                item.compressedThumbnail = nil
                item.originalSize = PDFCompressor.fileSize(item.url)
            }
            item.status = .waiting
            item.progress = 0
        }
        let profile = selectedProfile
        let settings = RunSettings(
            profile: profile, profileName: displayName(of: profile),
            location: self.settings.outputLocation, keepOriginal: self.settings.keepOriginalIfLarger
        )
        isCompressing = true
        isCancelling = false
        runItems = targets
        runProgress = 0
        timeRemaining = nil
        runEstimate = TimeEstimate()
        runTask = Task { await run(targets, settings) }
    }

    /// Stops the current run. Files not done yet stay as they were before it.
    func cancel() {
        guard isCompressing, !isCancelling else { return }
        isCancelling = true
        runTask?.cancel()
    }

    private func run(_ targets: [PDFItem], _ settings: RunSettings) async {
        var outputs: [URL] = []
        await withTaskGroup(of: URL?.self) { group in
            var queue = targets.makeIterator()
            for _ in 0..<Self.concurrentFiles {
                guard let item = queue.next() else { break }
                group.addTask { await self.compressOne(item, settings) }
            }
            while let output = await group.next() {
                if let output { outputs.append(output) }
                if !Task.isCancelled, let item = queue.next() {
                    group.addTask { await self.compressOne(item, settings) }
                }
            }
        }
        for item in targets where item.status == .waiting || item.status == .compressing {
            item.status = .ready
            item.progress = 0
        }
        isCompressing = false
        isCancelling = false
        runTask = nil
        runItems = []
        timeRemaining = nil
        if self.settings.revealWhenDone, !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Compresses one file of a run; returns the new file, if one was written.
    private func compressOne(_ item: PDFItem, _ settings: RunSettings) async -> URL? {
        guard !Task.isCancelled else { return nil }
        item.status = .compressing
        defer { updateRunProgress() }
        do {
            let result = try await Self.compressFile(item.url, password: item.password, settings) { fraction in
                Task { @MainActor in
                    guard item.status == .compressing else { return }
                    item.progress = fraction
                    self.updateRunProgress()
                }
            }
            item.progress = 1
            item.status = .done(result)
            item.profileName = settings.profileName
            let entry = record(result, profileName: settings.profileName)
            if current === item { selectedHistoryID = entry.id }
            if result.keptOriginal { return nil }
            if !isBatch { loadCompressedThumbnail(for: item, from: result.outputURL) }
            return result.outputURL
        } catch CompressionError.cancelled {
            item.status = .ready
            item.progress = 0
        } catch CompressionError.passwordRequired {
            item.status = .locked
        } catch {
            item.status = .failed(error.localizedDescription)
        }
        return nil
    }

    /// Runs the engine off the main actor, in the calling task, so that cancelling the task stops it.
    nonisolated private static func compressFile(
        _ url: URL, password: String?, _ settings: RunSettings, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CompressionResult {
        try PDFCompressor.compress(
            input: url, output: settings.location.destination(for: url), profile: settings.profile,
            password: password, keepOriginalIfLarger: settings.keepOriginal, progress: progress
        )
    }

    /// The run's progress, with each file weighed by its size.
    private func updateRunProgress() {
        guard isCompressing, !runItems.isEmpty else { return }
        var total = 0.0, done = 0.0
        for item in runItems {
            let weight = Double(max(item.originalSize, 1))
            total += weight
            switch item.status {
            case .compressing: done += weight * item.progress
            case .done, .failed, .locked: done += weight
            default: break
            }
        }
        runProgress = done / total
        runEstimate.update(fraction: runProgress)
        timeRemaining = runEstimate.remaining
    }
}
