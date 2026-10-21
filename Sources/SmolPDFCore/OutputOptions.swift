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
    /// Never returns an existing file, except for `.replaceOriginal`, nor one in `taken`: files that are
    /// still being written, e.g. by other files of the same batch.
    public func destination(for input: URL, excluding taken: Set<URL> = []) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        switch self {
        case .replaceOriginal:
            return input
        case .sameFolder(let suffix):
            let suffix = suffix.isEmpty ? "-compressed" : suffix
            return Self.unique(in: input.deletingLastPathComponent(), base: base + suffix, excluding: taken)
        case .folder(let folder):
            let candidate = folder.appendingPathComponent(base).appendingPathExtension("pdf")
            if candidate.standardizedFileURL == input.standardizedFileURL {
                return Self.unique(in: folder, base: base + "-compressed", excluding: taken)
            }
            return Self.unique(in: folder, base: base, excluding: taken)
        }
    }

    static func unique(in folder: URL, base: String, excluding taken: Set<URL> = []) -> URL {
        let fm = FileManager.default
        let taken = Set(taken.map(\.standardizedFileURL))
        var url = folder.appendingPathComponent(base).appendingPathExtension("pdf")
        var n = 2
        while fm.fileExists(atPath: url.path) || taken.contains(url.standardizedFileURL) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("pdf")
            n += 1
        }
        return url
    }
}
