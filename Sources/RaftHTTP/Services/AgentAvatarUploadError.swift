import Foundation

/// The avatar upload refusals shared by the profile and server avatar routes.
///
/// Upstream `avatarService`: the multipart field is `avatar`, the file must be
/// JPEG/PNG/GIF/WebP and at most 5 MB. The oversize body is the established
/// `AgentPrivateSurfaceError.avatarTooLarge`; the two refusals below are the
/// ones that body does not cover.
public enum AgentAvatarUploadError: DomainError, Equatable {
    case noAvatarFile
    case badFormat

    /// `MAX_PROFILE_AVATAR_BYTES`.
    public static let maximumBytes = 5 * 1024 * 1024
    /// `PROFILE_AVATAR_MIME_TYPES`.
    public static let allowedMimeTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp",
    ]

    public var status: UInt { 400 }

    public var errorMessage: String {
        switch self {
        case .noAvatarFile:
            "No avatar file provided"
        case .badFormat:
            "Only image files are allowed (JPEG, PNG, GIF, WebP)"
        }
    }

    public var errorCode: String? {
        switch self {
        case .noAvatarFile:
            nil
        case .badFormat:
            "PROFILE_AVATAR_BAD_FORMAT"
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .noAvatarFile:
            nil
        case .badFormat:
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "PROFILE_AVATAR_BAD_FORMAT"),
            ])
        }
    }

    /// `multer`'s file filter decision: a part without a usable content type is
    /// `application/octet-stream` and is refused.
    public static func validatedMimeType(_ raw: String?) throws -> String {
        let normalized = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedMimeTypes.contains(normalized) else { throw AgentAvatarUploadError.badFormat }
        return normalized
    }
}
