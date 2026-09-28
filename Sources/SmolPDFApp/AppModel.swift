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
    var status: Status = .ready
    var password: String?

    init(url: URL) {
        self.url = url
        self.originalSize = PDFCompressor.fileSize(url)
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

    var items: [PDFItem] = []
    var customProfiles: [CompressionProfile] = [] { didSet { saveProfiles() } }
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
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.profiles),
           let profiles = try? JSONDecoder().decode([CompressionProfile].self, from: data) {
            customProfiles = profiles
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

    // MARK: Files

    func add(_ urls: [URL]) {
        let known = Set(items.map { $0.url.standardizedFileURL })
        let newItems = PDFFinder.pdfs(in: urls)
            .filter { !known.contains($0.standardizedFileURL) }
            .map(PDFItem.init)
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        for item in newItems { loadDetails(for: item) }
        if settings.compressOnDrop { compressAll() }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose PDF files or folders to compress"
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func remove(_ ids: Set<PDFItem.ID>) {
        items.removeAll { ids.contains($0.id) && $0.status != .compressing }
    }

    func clear() {
        items.removeAll { $0.status != .compressing }
    }

    func clearFinished() {
        items.removeAll { $0.isFinished }
    }

    private func loadDetails(for item: PDFItem) {
        let url = item.url
        Task.detached(priority: .userInitiated) {
            let doc = PDFDocument(url: url)
            let locked = doc?.isLocked ?? false
            let pages = doc?.pageCount ?? 0
            let thumb = locked ? nil : doc?.page(at: 0)?.thumbnail(of: CGSize(width: 120, height: 160), for: .cropBox)
            await MainActor.run {
                item.pageCount = pages
                item.thumbnail = thumb
                if doc == nil {
                    item.status = .failed(CompressionError.cannotOpen.localizedDescription)
                } else if locked {
                    item.status = .locked
                }
            }
        }
    }

    func unlock(_ item: PDFItem, password: String) -> Bool {
        guard let doc = PDFDocument(url: item.url), doc.unlock(withPassword: password) else { return false }
        item.password = password
        item.pageCount = doc.pageCount
        item.thumbnail = doc.page(at: 0)?.thumbnail(of: CGSize(width: 120, height: 160), for: .cropBox)
        item.status = .ready
        return true
    }

    // MARK: Compression

    var pendingItems: [PDFItem] { items.filter { $0.status == .ready } }

    var canCompress: Bool { !isCompressing && !pendingItems.isEmpty }

    /// Re-queues finished items so they can be compressed again, e.g. with another profile.
    func resetFinished() {
        for item in items where item.isFinished {
            item.status = .ready
            item.originalSize = PDFCompressor.fileSize(item.url)
        }
    }

    func compressAll() {
        guard !isCompressing else { return }
        if pendingItems.isEmpty { resetFinished() }
        let queue = pendingItems
        guard !queue.isEmpty else { return }
        compress(queue)
    }

    func compress(_ queue: [PDFItem]) {
        isCompressing = true
        let profile = selectedProfile
        let location = settings.outputLocation
        let keepOriginal = settings.keepOriginalIfLarger
        let jobs = queue.map { ($0, $0.url, $0.password) }
        for (item, _, _) in jobs { item.status = .compressing }

        Task {
            let width = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
            await withTaskGroup(of: Void.self) { group in
                for (index, (item, url, password)) in jobs.enumerated() {
                    // Limit how many files are processed at once.
                    if index >= width { await group.next() }
                    group.addTask {
                        let outcome: Result<CompressionResult, Error> = await Task.detached(priority: .userInitiated) {
                            Result {
                                try PDFCompressor.compress(
                                    input: url, output: location.destination(for: url), profile: profile,
                                    password: password, keepOriginalIfLarger: keepOriginal
                                )
                            }
                        }.value
                        await MainActor.run {
                            switch outcome {
                            case .success(let result): item.status = .done(result)
                            case .failure(let error): item.status = .failed(error.localizedDescription)
                            }
                        }
                    }
                }
            }
            isCompressing = false
            finished(jobs.map(\.0))
        }
    }

    private func finished(_ batch: [PDFItem]) {
        let outputs = batch.compactMap(\.result).filter { !$0.keptOriginal }.map(\.outputURL)
        if settings.revealWhenDone, !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: Totals

    var totalOriginal: Int64 { items.reduce(0) { $0 + $1.originalSize } }

    var finishedResults: [CompressionResult] { items.compactMap(\.result) }
}
