import Foundation
import UniformTypeIdentifiers

public enum PDFFinder {
    /// Expands the given files and folders into a flat list of PDF files. Folders are searched recursively
    /// and their PDFs listed in the Finder's order; a file given more than once is listed once.
    public static func pdfs(in urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            if seen.insert(url.standardizedFileURL.path).inserted { result.append(url) }
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = fm.enumerator(
                    at: url, includingPropertiesForKeys: [.contentTypeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                var found: [URL] = []
                while let file = enumerator?.nextObject() as? URL {
                    if isPDF(file) { found.append(file) }
                }
                found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.forEach(add)
            } else if isPDF(url) {
                add(url)
            }
        }
        return result
    }

    public static func isPDF(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf)
        }
        return url.pathExtension.lowercased() == "pdf"
    }
}
