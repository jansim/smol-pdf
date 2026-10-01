import Foundation
import SmolPDFEngine

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
    /// What was changed (not stored in the history).
    public var details: CompressionDetails? = nil

    public init(
        inputURL: URL, outputURL: URL, originalSize: Int64, compressedSize: Int64,
        keptOriginal: Bool, trashedURL: URL? = nil, details: CompressionDetails? = nil
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        self.keptOriginal = keptOriginal
        self.trashedURL = trashedURL
        self.details = details
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

/// What compression changed in a document.
public struct CompressionDetails: Hashable, Sendable {
    public var images: Int
    /// Images stored in a new form (a smaller encoding, fewer pixels, or fewer colors).
    public var imagesChanged: Int
    public var imagesDownsampled: Int
    /// Size of the changed images before and after.
    public var imageBytesBefore: Int64
    public var imageBytesAfter: Int64
    /// Other data (page content, fonts, ...) stored with better compression.
    public var streamsRecompressed: Int
    /// Identical objects stored only once.
    public var duplicatesRemoved: Int
}

public enum CompressionError: LocalizedError, Equatable {
    case cannotOpen
    case passwordRequired
    case wrongPassword
    case writeFailed
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen: "The file is not a readable PDF."
        case .passwordRequired: "The PDF is password protected."
        case .wrongPassword: "The password is incorrect."
        case .writeFailed: "The compressed PDF could not be written."
        case .failed(let reason): "The PDF could not be compressed: \(reason)"
        }
    }
}

public enum PDFCompressor {
    /// Compresses `input` according to `profile` and writes the result to `output`.
    ///
    /// The engine (Sources/SmolPDFEngine) re-encodes each image in the format that suits it best, keeps
    /// text and vector graphics intact, and cleans up the file structure. Encryption is kept.
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

        let workDir = try fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: output.deletingLastPathComponent(), create: true
        )
        defer { try? fm.removeItem(at: workDir) }
        let tempURL = workDir.appendingPathComponent("out.pdf")
        let details = try runEngine(input: input, output: tempURL, profile: profile, password: password)

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
            trashedURL: trashedURL as URL?, details: details
        )
    }

    public static func fileSize(_ url: URL) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return size?.int64Value ?? 0
    }

    private static func runEngine(
        input: URL, output: URL, profile: CompressionProfile, password: String?
    ) throws -> CompressionDetails {
        var options = SmolOptions()
        smol_default_options(&options)
        options.lossy_images = profile.compressImages ? 1 : 0
        options.jpeg_quality = profile.imageQuality
        options.max_resolution = Int32(profile.compressImages ? profile.maxResolution ?? 0 : 0)
        options.grayscale = profile.grayscale ? 1 : 0
        options.monochrome_scans = profile.monochromeScans ? 1 : 0
        options.remove_metadata = profile.removeMetadata ? 1 : 0
        options.remove_editing_data = profile.removeEditingData ? 1 : 0
        options.remove_annotations = profile.removeAnnotations ? 1 : 0
        options.remove_bookmarks = profile.removeBookmarks ? 1 : 0
        options.remove_attachments = profile.removeAttachments ? 1 : 0
        options.remove_javascript = profile.removeJavaScript ? 1 : 0

        var stats = SmolStats()
        let messageSize = 1024
        var message = [CChar](repeating: 0, count: messageSize)
        let status = input.withUnsafeFileSystemRepresentation { inputPath in
            output.withUnsafeFileSystemRepresentation { outputPath in
                withOptionalCString(password) { passwordPath in
                    smol_compress(inputPath, outputPath, passwordPath, &options, &stats, &message, messageSize)
                }
            }
        }
        switch status {
        case SMOL_OK:
            return CompressionDetails(
                images: stats.images, imagesChanged: stats.images_changed, imagesDownsampled: stats.images_downsampled,
                imageBytesBefore: stats.image_bytes_before, imageBytesAfter: stats.image_bytes_after,
                streamsRecompressed: stats.streams_recompressed, duplicatesRemoved: stats.duplicates_removed
            )
        case SMOL_ERROR_PASSWORD_REQUIRED: throw CompressionError.passwordRequired
        case SMOL_ERROR_WRONG_PASSWORD: throw CompressionError.wrongPassword
        case SMOL_ERROR_OPEN: throw CompressionError.cannotOpen
        case SMOL_ERROR_WRITE: throw CompressionError.writeFailed
        default: throw CompressionError.failed(String(cString: message))
        }
    }

    private static func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let string else { return body(nil) }
        return string.withCString(body)
    }
}
