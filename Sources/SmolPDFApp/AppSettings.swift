import Foundation
import Observation
import SmolPDFCore

@Observable
@MainActor
final class AppSettings {
    enum Destination: String, CaseIterable, Identifiable {
        case sameFolder, folder, replace
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sameFolder: "Next to the original"
            case .folder: "In a folder"
            case .replace: "Replace the original"
            }
        }
    }

    var destination: Destination { didSet { store(destination.rawValue, "destination") } }
    var suffix: String { didSet { store(suffix, "suffix") } }
    var outputFolder: URL? { didSet { store(outputFolder?.path, "outputFolder") } }
    var keepOriginalIfLarger: Bool { didSet { store(keepOriginalIfLarger, "keepOriginalIfLarger") } }
    var compressOnDrop: Bool { didSet { store(compressOnDrop, "compressOnDrop") } }
    var revealWhenDone: Bool { didSet { store(revealWhenDone, "revealWhenDone") } }

    init() {
        let d = UserDefaults.standard
        destination = d.string(forKey: "destination").flatMap(Destination.init) ?? .sameFolder
        suffix = d.string(forKey: "suffix") ?? "-compressed"
        outputFolder = d.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        keepOriginalIfLarger = d.object(forKey: "keepOriginalIfLarger") as? Bool ?? true
        compressOnDrop = d.bool(forKey: "compressOnDrop")
        revealWhenDone = d.bool(forKey: "revealWhenDone")
    }

    var outputLocation: OutputLocation {
        switch destination {
        case .sameFolder: .sameFolder(suffix: suffix)
        case .replace: .replaceOriginal
        case .folder:
            if let outputFolder { .folder(outputFolder) } else { .sameFolder(suffix: suffix) }
        }
    }

    var destinationSummary: String {
        switch destination {
        case .sameFolder: "Saved next to originals as “name\(suffix.isEmpty ? "-compressed" : suffix).pdf”"
        case .replace: "Originals are replaced (moved to the Trash)"
        case .folder: outputFolder.map { "Saved to \($0.lastPathComponent)" } ?? "No output folder chosen"
        }
    }

    private func store(_ value: Any?, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
