/// GET /api/messages/attachment-preview/enabled returns the configured gate.
/// This flag does not advertise support for every preview format.
public struct AttachmentPreviewAvailabilityResponse: JSONBodyConvertible, Sendable, Equatable {
    public let enabled: Bool

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("enabled", enabled)])
    }
}

/// The pinned router's absent-direct-upload-service branch, not an inventory
/// of resumable sessions. Current direct-upload writers remain unavailable.
public struct AbsentAttachmentUploadRecoveryResponse: JSONBodyConvertible, Sendable, Equatable {
    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("uploads", .array([]))])
    }
}

public enum AttachmentReadCapabilitiesError: DomainError, Equatable {
    case missingServerIdHeader
    case notAServerMember
    case invalidChannelId

    public var status: UInt {
        switch self {
        case .missingServerIdHeader, .invalidChannelId: 400
        case .notAServerMember: 403
        }
    }

    public var errorMessage: String {
        switch self {
        case .missingServerIdHeader: "Missing X-Server-Id header"
        case .notAServerMember: "Not a member of this server"
        case .invalidChannelId: "The channel id is invalid."
        }
    }

    public var errorBody: OrderedJSON? {
        guard self == .invalidChannelId else { return nil }
        return .object([
            OrderedJSONField("code", "UPLOAD_INVALID_REQUEST"),
            OrderedJSONField("message", errorMessage),
            OrderedJSONField("retryable", false),
        ])
    }
}
