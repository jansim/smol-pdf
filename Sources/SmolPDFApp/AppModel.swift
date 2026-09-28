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

    /// The file shown in the window.
    var current: PDFItem?
    /// The history entry of the current file, highlighted in the sidebar.
    var selectedHistoryID: HistoryEntry.ID?
    var customProfiles: [CompressionProfile] = [] { didSet { saveProfiles() } }
    /// Finished compressions, newest first. Persists across launches.
    var history: [HistoryEntry] = [] { didSet { saveHistory() } }
    var selectedProfileID: UUID = CompressionProfile.medium.id {
        didSet { UserDefaults.standard.set(selectedProfileID.uuidString, forKey: Keys.selectedProfile) }
    }
    var isCompressing = false
    /// Item whose password is being asked for.
    var unlockItem: PDFItem?
    /// Item shown in the before/after comparison.
    var compareItem: PDFItem?

    let settings = AppSettings()

    private enum Keys {
        static let profiles = "customProfiles"
        static let selectedProfile = "selectedProfile"
        static let history = "history"
    }

    private static let historyLimit = 200

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.profiles),
           let profiles = try? JSONDecoder().decode([CompressionProfile].self, from: data) {
            customProfiles = profiles
        }
        if let data = UserDefaults.standard.data(forKey: Keys.history),
           let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = entries
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.selectedProfile),
           let id = UUID(uuidString: raw), allProfiles.contains(where: { $0.id == id }) {
            selectedProfileID = id
        }
    }

    // MARK: Profiles

    var allProfiles: [CompressionProfile] { CompressionProfile.builtIns + customProfiles }

    var selectedProfile: CompressionProfile {
        allProfiles.first { $0.id == selectedProfileID } ?? .medium
    }

    func updateProfile(_ profile: CompressionProfile) {
        guard let index = customProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        customProfiles[index] = profile
    }

    @discardableResult
    func duplicateSelectedProfile() -> CompressionProfile {
        let base = selectedProfile
        var name = base.isBuiltIn ? "Custom" : "\(base.name) Copy"
        var n = 2
        while allProfiles.contains(where: { $0.name == name }) {
            name = (base.isBuiltIn ? "Custom" : "\(base.name) Copy") + " \(n)"
            n += 1
        }
        let copy = base.duplicate(named: name)
        customProfiles.append(copy)
        selectedProfileID = copy.id
        return copy
    }

    func deleteProfile(_ id: UUID) {
        customProfiles.removeAll { $0.id == id }
        if selectedProfileID == id { selectedProfileID = CompressionProfile.medium.id }
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(customProfiles) {
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
        selectedHistoryID = id
        guard let id, let entry = history.first(where: { $0.id == id }) else { return }
        let item = PDFItem(entry: entry)
        current = item
        loadThumbnail(for: item, from: entry.result.originalURL)
        if !entry.keptOriginal { loadCompressedThumbnail(for: item, from: entry.outputURL) }
    }

    private func record(_ result: CompressionResult, profile: CompressionProfile) -> HistoryEntry {
        let entry = HistoryEntry(result: result, profileName: profile.name)
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

    /// Opens the first PDF among `urls`, replacing the current file.
    func add(_ urls: [URL]) {
        guard !isCompressing, let url = PDFFinder.pdfs(in: urls).first else { return }
        let item = PDFItem(url: url)
        current = item
        selectedHistoryID = nil
        loadDetails(for: item)
        if settings.compressOnDrop { compress() }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose a PDF file to compress"
        panel.prompt = "Open"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func close() {
        guard !isCompressing else { return }
        current = nil
        selectedHistoryID = nil
    }

    private func loadDetails(for item: PDFItem) {
        let url = item.url
        Task.detached(priority: .userInitiated) {
            let doc = PDFDocument(url: url)
            let locked = doc?.isLocked ?? false
            let pages = doc?.pageCount ?? 0
            let thumb = locked ? nil : doc?.page(at: 0)?.thumbnail(of: Self.thumbnailSize, for: .cropBox)
            await MainActor.run {
                item.pageCount = pages
                item.thumbnail = thumb
                guard item.status == .ready else { return }
                if doc == nil {
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
        item.thumbnail = doc.page(at: 0)?.thumbnail(of: Self.thumbnailSize, for: .cropBox)
        item.status = .ready
        return true
    }

    // MARK: Compression

    var canCompress: Bool {
        guard !isCompressing, let current else { return false }
        return current.status == .ready || current.isFinished
    }

    /// Compresses the current file, again if it was compressed already, e.g. with another profile.
    func compress() {
        guard canCompress, let item = current else { return }
        if item.isFinished {
            // After replacing the original, the item's file is now the compressed one.
            if item.result?.outputURL == item.url, let thumbnail = item.compressedThumbnail {
                item.thumbnail = thumbnail
            }
            item.compressedThumbnail = nil
            item.originalSize = PDFCompressor.fileSize(item.url)
        }
        isCompressing = true
        item.status = .compressing
        let profile = selectedProfile
        let location = settings.outputLocation
        let keepOriginal = settings.keepOriginalIfLarger
        let url = item.url, password = item.password

        Task {
            let outcome: Result<CompressionResult, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try PDFCompressor.compress(
                        input: url, output: location.destination(for: url), profile: profile,
                        password: password, keepOriginalIfLarger: keepOriginal
                    )
                }
            }.value
            switch outcome {
            case .success(let result):
                item.status = .done(result)
                item.profileName = profile.name
                let entry = record(result, profile: profile)
                if current === item { selectedHistoryID = entry.id }
                if !result.keptOriginal { loadCompressedThumbnail(for: item, from: result.outputURL) }
                if settings.revealWhenDone, !result.keptOriginal {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
            case .failure(let error):
                item.status = .failed(error.localizedDescription)
            }
            isCompressing = false
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }
}
