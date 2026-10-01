import Foundation

/// A named set of compression settings. Built-in profiles are fixed; custom profiles are user-editable.
public struct CompressionProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isBuiltIn: Bool

    /// Allow lossy image changes: JPEG re-encoding and downsampling. When false, images are only
    /// stored more efficiently, without changing a single pixel (lossless).
    public var compressImages: Bool
    /// JPEG quality, 0 (smallest) ... 1 (best).
    public var imageQuality: Double
    /// Downsample images above this resolution (in DPI). `nil` keeps the original resolution.
    public var maxResolution: Int?
    /// Store black-and-white scans as 1-bit images (sharper and much smaller than gray JPEGs).
    public var monochromeScans: Bool

    public var grayscale: Bool
    public var removeMetadata: Bool
    /// Private application data (such as Illustrator's editing data) and page thumbnails.
    public var removeEditingData: Bool
    public var removeAnnotations: Bool
    public var removeBookmarks: Bool
    public var removeAttachments: Bool
    public var removeJavaScript: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        isBuiltIn: Bool = false,
        compressImages: Bool = true,
        imageQuality: Double = 0.6,
        maxResolution: Int? = 150,
        monochromeScans: Bool = false,
        grayscale: Bool = false,
        removeMetadata: Bool = false,
        removeEditingData: Bool = false,
        removeAnnotations: Bool = false,
        removeBookmarks: Bool = false,
        removeAttachments: Bool = false,
        removeJavaScript: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.compressImages = compressImages
        self.imageQuality = imageQuality
        self.maxResolution = maxResolution
        self.monochromeScans = monochromeScans
        self.grayscale = grayscale
        self.removeMetadata = removeMetadata
        self.removeEditingData = removeEditingData
        self.removeAnnotations = removeAnnotations
        self.removeBookmarks = removeBookmarks
        self.removeAttachments = removeAttachments
        self.removeJavaScript = removeJavaScript
    }

    /// Settings added later are missing from saved profiles and take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CompressionProfile(name: "")
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        compressImages = try c.decodeIfPresent(Bool.self, forKey: .compressImages) ?? defaults.compressImages
        imageQuality = try c.decodeIfPresent(Double.self, forKey: .imageQuality) ?? defaults.imageQuality
        maxResolution = try c.decodeIfPresent(Int.self, forKey: .maxResolution)
        monochromeScans = try c.decodeIfPresent(Bool.self, forKey: .monochromeScans) ?? defaults.monochromeScans
        grayscale = try c.decodeIfPresent(Bool.self, forKey: .grayscale) ?? defaults.grayscale
        removeMetadata = try c.decodeIfPresent(Bool.self, forKey: .removeMetadata) ?? defaults.removeMetadata
        removeEditingData = try c.decodeIfPresent(Bool.self, forKey: .removeEditingData) ?? defaults.removeEditingData
        removeAnnotations = try c.decodeIfPresent(Bool.self, forKey: .removeAnnotations) ?? defaults.removeAnnotations
        removeBookmarks = try c.decodeIfPresent(Bool.self, forKey: .removeBookmarks) ?? defaults.removeBookmarks
        removeAttachments = try c.decodeIfPresent(Bool.self, forKey: .removeAttachments) ?? defaults.removeAttachments
        removeJavaScript = try c.decodeIfPresent(Bool.self, forKey: .removeJavaScript) ?? defaults.removeJavaScript
    }

    /// A one-line description of what the profile does, e.g. "150 dpi · JPEG 60%".
    public var summary: String {
        var parts: [String] = []
        if compressImages {
            parts.append(maxResolution.map { "\($0) dpi" } ?? "Original resolution")
            parts.append("JPEG \(Int((imageQuality * 100).rounded()))%")
        } else {
            parts.append("Lossless")
        }
        if grayscale { parts.append("Grayscale") }
        if removeMetadata { parts.append("No metadata") }
        return parts.joined(separator: " · ")
    }

    /// A copy of this profile that can be edited.
    public func duplicate(named newName: String? = nil) -> CompressionProfile {
        var copy = self
        copy.id = UUID()
        copy.name = newName ?? "\(name) Copy"
        copy.isBuiltIn = false
        return copy
    }
}

extension CompressionProfile {
    public static let lossless = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Lossless", isBuiltIn: true,
        compressImages: false, imageQuality: 1, maxResolution: nil
    )
    public static let low = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Low", isBuiltIn: true,
        imageQuality: 0.8, maxResolution: 300
    )
    public static let medium = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Medium", isBuiltIn: true,
        imageQuality: 0.6, maxResolution: 150, removeEditingData: true
    )
    public static let high = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        name: "High", isBuiltIn: true,
        imageQuality: 0.4, maxResolution: 110, monochromeScans: true,
        removeMetadata: true, removeEditingData: true
    )
    public static let maximum = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        name: "Maximum", isBuiltIn: true,
        imageQuality: 0.2, maxResolution: 72, monochromeScans: true,
        removeMetadata: true, removeEditingData: true
    )

    public static let builtIns: [CompressionProfile] = [.lossless, .low, .medium, .high, .maximum]
}
