import Foundation
import SmolPDFEngine

/// What the engine changed in a document.
public struct CompressionDetails: Hashable, Sendable {
    /// Images in the document.
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

/// The qpdf-based compression engine (Sources/SmolPDFEngine).
enum SmolEngine {
    static func compress(input: URL, output: URL, profile: CompressionProfile, password: String?) throws -> CompressionDetails {
        var options = SmolOptions()
        smol_default_options(&options)
        options.lossy_images = profile.compressImages ? 1 : 0
        options.jpeg_quality = profile.imageQuality
        options.max_resolution = Int32(profile.compressImages ? profile.maxResolution ?? 0 : 0)
        options.grayscale_images = profile.grayscale ? 1 : 0
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
                withOptionalCString(password) { passwordPtr in
                    smol_compress(inputPath, outputPath, passwordPtr, &options, &stats, &message, messageSize)
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
        default: throw EngineError(message: String(cString: message))
        }
    }

    struct EngineError: Error {
        var message: String
    }

    private static func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let string else { return body(nil) }
        return string.withCString(body)
    }
}
