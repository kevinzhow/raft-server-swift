import Foundation

public enum AttachmentContentError: DomainError, Equatable {
    case noFiles
    case invalidMultipart
    case missingServerScope
    case channelIdRequired
    case cannotWriteChannel
    case channelArchived
    case uploadsNotConfigured
    case downloadsNotConfigured
    case uploadFailed
    case downloadFailed
    case notPreviewableHTML
    case previewFailed
    case previewURLFailed
    case invalidPreviewToken
    case bearerPreviewForbidden

    public var status: UInt {
        switch self {
        case .noFiles, .invalidMultipart, .missingServerScope, .channelIdRequired: 400
        case .cannotWriteChannel: 403
        case .channelArchived: 409
        case .uploadsNotConfigured, .downloadsNotConfigured: 503
        case .uploadFailed, .downloadFailed, .previewFailed, .previewURLFailed: 500
        case .invalidPreviewToken, .bearerPreviewForbidden: 403
        case .notPreviewableHTML: 415
        }
    }

    public var errorMessage: String {
        switch self {
        case .noFiles: "No files provided"
        case .invalidMultipart: "Invalid multipart upload"
        case .missingServerScope: "Missing X-Server-Id"
        case .channelIdRequired: "channelId is required"
        case .cannotWriteChannel: "You do not have access to this channel"
        case .channelArchived: "This channel is archived"
        case .uploadsNotConfigured: "File uploads are not configured on this server"
        case .downloadsNotConfigured: "File storage is not configured on this server"
        case .uploadFailed: "Failed to upload files"
        case .downloadFailed: "Failed to serve attachment"
        case .notPreviewableHTML: "Attachment is not previewable HTML"
        case .previewFailed: "Failed to serve HTML preview"
        case .previewURLFailed: "Failed to get HTML preview URL"
        case .invalidPreviewToken: "Invalid attachment preview token"
        case .bearerPreviewForbidden: "User bearer query tokens cannot authorize HTML preview"
        }
    }

    public var errorCode: String? { self == .channelArchived ? "channel_archived" : nil }
    public var errorBody: OrderedJSON? { nil }
}
