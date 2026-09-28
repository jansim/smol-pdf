import Foundation
import PDFKit
import Quartz

public struct CompressionResult: Hashable, Sendable {
    public var inputURL: URL
    /// Where the result lives. Equals `inputURL` when the original was kept.
    public var outputURL: URL
    public var originalSize: Int64
    public var compressedSize: Int64
    /// True when compression could not make the file smaller and the original was kept.
    public var keptOriginal: Bool
    /// Where the file previously at `outputURL` ended up in the Trash, e.g. the original when replacing it.
    public var trashedURL: URL? = nil

    public init(
        inputURL: URL, outputURL: URL, originalSize: Int64, compressedSize: Int64,
        keptOriginal: Bool, trashedURL: URL? = nil
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        self.keptOriginal = keptOriginal
        self.trashedURL = trashedURL
    }

    /// The uncompressed file: the input, or its copy in the Trash when it was replaced.
    public var originalURL: URL {
        outputURL == inputURL && !keptOriginal ? trashedURL ?? inputURL : inputURL
    }

    public var savedBytes: Int64 { max(0, originalSize - compressedSize) }
    public var savedFraction: Double {
        originalSize > 0 ? Double(savedBytes) / Double(originalSize) : 0
    }
}

public enum CompressionError: LocalizedError, Equatable {
    case cannotOpen
    case passwordRequired
    case wrongPassword
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .cannotOpen: "The file is not a readable PDF."
        case .passwordRequired: "The PDF is password protected."
        case .wrongPassword: "The password is incorrect."
        case .writeFailed: "The compressed PDF could not be written."
        }
    }
}

public enum PDFCompressor {
    /// Compresses `input` according to `profile` and writes the result to `output`.
    ///
    /// Images are re-encoded through a Quartz filter, which keeps text and vector graphics intact.
    /// If `output` already exists it is moved to the Trash first (this is how "replace original" works).
    /// With `keepOriginalIfLarger`, a result that isn't smaller than the input is discarded.
    public static func compress(
        input: URL,
        output: URL,
        profile: CompressionProfile,
        password: String? = nil,
        keepOriginalIfLarger: Bool = true
    ) throws -> CompressionResult {
        let fm = FileManager.default
        let originalSize = fileSize(input)

        guard let document = PDFDocument(url: input) else { throw CompressionError.cannotOpen }
        var writeOptions: [PDFDocumentWriteOption: Any] = [:]
        if document.isLocked {
            guard let password, !password.isEmpty else { throw CompressionError.passwordRequired }
            guard document.unlock(withPassword: password) else { throw CompressionError.wrongPassword }
            // Keep the output protected with the same password.
            writeOptions[.userPasswordOption] = password
            writeOptions[.ownerPasswordOption] = password
        }

        applyStructuralChanges(to: document, profile: profile)

        let workDir = try fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: output.deletingLastPathComponent(), create: true
        )
        defer { try? fm.removeItem(at: workDir) }

        if let filter = makeFilter(for: profile) {
            writeOptions[.quartzFilter] = filter
        }
        let tempURL = workDir.appendingPathComponent("out.pdf")
        guard document.write(to: tempURL, withOptions: writeOptions) else { throw CompressionError.writeFailed }

        let compressedSize = fileSize(tempURL)
        if keepOriginalIfLarger && compressedSize >= originalSize {
            return CompressionResult(
                inputURL: input, outputURL: input,
                originalSize: originalSize, compressedSize: originalSize, keptOriginal: true
            )
        }

        var trashedURL: NSURL?
        if fm.fileExists(atPath: output.path) {
            try fm.trashItem(at: output, resultingItemURL: &trashedURL)
        }
        try fm.moveItem(at: tempURL, to: output)
        return CompressionResult(
            inputURL: input, outputURL: output,
            originalSize: originalSize, compressedSize: compressedSize, keptOriginal: false,
            trashedURL: trashedURL as URL?
        )
    }

    static func applyStructuralChanges(to document: PDFDocument, profile: CompressionProfile) {
        if profile.removeMetadata {
            document.documentAttributes = [:]
        }
        if profile.removeBookmarks {
            document.outlineRoot = nil
        }
        if profile.removeAnnotations {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for annotation in page.annotations { page.removeAnnotation(annotation) }
            }
        }
    }

    /// Builds the ColorSync filter that is applied while writing, or `nil` when nothing needs filtering.
    ///
    /// Image settings are the same mechanism as Preview's "Reduce File Size" filter, with tunable values.
    /// Grayscale reuses the system "Gray Tone" filter and merges the image settings into it, so
    /// everything happens in a single pass.
    static func makeFilter(for profile: CompressionProfile) -> QuartzFilter? {
        var properties: [String: Any]
        if profile.grayscale, let gray = grayscaleFilter()?.properties() as? [String: Any] {
            properties = gray
        } else if profile.compressImages {
            properties = [
                "Name": "smol-pdf",
                "FilterType": 1,
                "Domains": ["Applications": true, "Printing": true],
            ]
        } else {
            return nil
        }

        if profile.compressImages {
            var data = properties["FilterData"] as? [String: Any] ?? [:]
            var colorSettings = data["ColorSettings"] as? [String: Any] ?? [:]
            colorSettings["ImageSettings"] = imageSettings(quality: profile.imageQuality, maxResolution: profile.maxResolution)
            data["ColorSettings"] = colorSettings
            properties["FilterData"] = data
        }
        return QuartzFilter(properties: properties)
    }

    static func imageSettings(quality: Double, maxResolution: Int?) -> [String: Any] {
        var settings: [String: Any] = [
            "Compression Quality": min(max(quality, 0), 1),
            "ImageCompression": "ImageJPEGCompress",
        ]
        if let maxResolution, maxResolution > 0 {
            settings["ImageScaleSettings"] = [
                "ImageResolution": maxResolution,
                "ImageScaleFactor": 0.0,
                "ImageScaleInterpolate": true,
                "ImageSizeMax": 0,
                "ImageSizeMin": 128,
            ] as [String: Any]
        }
        return settings
    }

    /// The system "Gray Tone" filter, looked up by file name so it works in every language.
    static func grayscaleFilter() -> QuartzFilter? {
        let all = (QuartzFilterManager.filters(inDomains: nil) as? [QuartzFilter]) ?? []
        return all.first { $0.url()?.lastPathComponent == "Gray Tone.qfilter" }
    }

    public static func fileSize(_ url: URL) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return size?.int64Value ?? 0
    }
}

extension PDFDocumentWriteOption {
    /// Undocumented but long-standing PDFKit option that runs a `QuartzFilter` while writing.
    static let quartzFilter = PDFDocumentWriteOption(rawValue: "QuartzFilter")
}
