import Foundation

/// A named set of compression settings. Built-in profiles are fixed; custom profiles are user-editable.
public struct CompressionProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isBuiltIn: Bool

    /// Re-encode images as JPEG. When false, images are left untouched (lossless).
    public var compressImages: Bool
    /// JPEG quality, 0 (smallest) ... 1 (best).
    public var imageQuality: Double
    /// Downsample images above this resolution (in DPI). `nil` keeps the original resolution.
    public var maxResolution: Int?

    public var grayscale: Bool
    public var removeMetadata: Bool
    public var removeAnnotations: Bool
    public var removeBookmarks: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        isBuiltIn: Bool = false,
        compressImages: Bool = true,
        imageQuality: Double = 0.6,
        maxResolution: Int? = 150,
        grayscale: Bool = false,
        removeMetadata: Bool = false,
        removeAnnotations: Bool = false,
        removeBookmarks: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.compressImages = compressImages
        self.imageQuality = imageQuality
        self.maxResolution = maxResolution
        self.grayscale = grayscale
        self.removeMetadata = removeMetadata
        self.removeAnnotations = removeAnnotations
        self.removeBookmarks = removeBookmarks
    }

    /// A one-line description of what the profile does, e.g. "150 dpi · JPEG 60%".
    public var summary: String {
        var parts: [String] = []
        if compressImages {
            parts.append(maxResolution.map { "\($0) dpi" } ?? "Original resolution")
            parts.append("JPEG \(Int((imageQuality * 100).rounded()))%")
        } else {
            parts.append("Images untouched")
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
        imageQuality: 0.6, maxResolution: 150
    )
    public static let high = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        name: "High", isBuiltIn: true,
        imageQuality: 0.4, maxResolution: 110, removeMetadata: true
    )
    public static let maximum = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        name: "Maximum", isBuiltIn: true,
        imageQuality: 0.2, maxResolution: 72, removeMetadata: true
    )

    public static let builtIns: [CompressionProfile] = [.lossless, .low, .medium, .high, .maximum]
}
