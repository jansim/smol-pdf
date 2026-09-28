import Foundation

/// Where compressed files are written.
public enum OutputLocation: Codable, Hashable, Sendable {
    /// Next to the original, with a suffix appended to the file name.
    case sameFolder(suffix: String)
    /// Overwrite the original; the original is moved to the Trash.
    case replaceOriginal
    /// Into a fixed folder, keeping the original file name.
    case folder(URL)

    public static let `default` = OutputLocation.sameFolder(suffix: "-compressed")

    /// The URL the compressed version of `input` should be written to.
    /// Never returns an existing file, except for `.replaceOriginal`.
    public func destination(for input: URL) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        switch self {
        case .replaceOriginal:
            return input
        case .sameFolder(let suffix):
            let suffix = suffix.isEmpty ? "-compressed" : suffix
            return Self.unique(in: input.deletingLastPathComponent(), base: base + suffix)
        case .folder(let folder):
            let candidate = folder.appendingPathComponent(base).appendingPathExtension("pdf")
            if candidate.standardizedFileURL == input.standardizedFileURL {
                return Self.unique(in: folder, base: base + "-compressed")
            }
            return Self.unique(in: folder, base: base)
        }
    }

    static func unique(in folder: URL, base: String) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent(base).appendingPathExtension("pdf")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("pdf")
            n += 1
        }
        return url
    }
}
