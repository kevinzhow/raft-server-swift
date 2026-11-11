import Foundation

/// One multipart file part after the `avatar`/`logo` field was located.
///
/// The declared MIME type is the multipart part's `Content-Type`, which is the
/// value multer's `fileFilter` sees upstream. The bytes stay exactly as
/// received; this port has no image re-encoder in its release closure, so the
/// stored object is the validated original (see `docs/DEVIATIONS.md` D23).
public struct AvatarUploadFile: Sendable, Equatable {
    public let bytes: Data
    public let contentType: String?
    public let filename: String?

    public init(bytes: Data, contentType: String?, filename: String?) {
        self.bytes = bytes
        self.contentType = contentType
        self.filename = filename
    }
}

/// The image formats upstream `avatarService` accepts
/// (`PROFILE_AVATAR_MIME_TYPES`). SVG is deliberately absent.
public enum AvatarImageFormat: String, Sendable, CaseIterable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case gif = "image/gif"
    case webp = "image/webp"

    /// The normalized multipart part type, or nil when the field is absent or
    /// not one of the four accepted types.
    public static func declared(_ raw: String?) -> Self? {
        guard let raw else { return nil }
        guard let part = raw.split(separator: ";", maxSplits: 1).first.map(String.init) else { return nil }
        let base = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.rawValue == base }
    }

    /// Detect the real format from the file signature. The upload route uses
    /// this both to refuse non-images and to serve the stored object with its
    /// actual content type.
    public static func sniff(_ bytes: Data) -> Self? {
        if bytes.count >= 6, (bytes.prefix(6) == Data("GIF87a".utf8) || bytes.prefix(6) == Data("GIF89a".utf8)) {
            return .gif
        }
        if bytes.count >= 8, bytes.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return .png
        }
        if bytes.count >= 3, bytes.prefix(3) == Data([0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if bytes.count >= 12,
           bytes.prefix(4) == Data("RIFF".utf8),
           bytes.dropFirst(8).prefix(4) == Data("WEBP".utf8) {
            return .webp
        }
        return nil
    }
}
