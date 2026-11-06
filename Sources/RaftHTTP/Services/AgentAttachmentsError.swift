import Foundation

/// Domain failure for the agent attachment download surface.
public enum AgentAttachmentsError: DomainError, Equatable {
    /// The attachment is missing or not visible to the agent.
    case unavailable
    /// The Server's file storage cannot mint download URLs.
    case downloadURLUnavailable
    case mintFailed

    static let unavailableMessage = "Attachment is unavailable."
    static let unavailableNextAction = "If this value came from a feedback report, do not use its artifactId here. Use the reportId with the Raft Feedback Admin integration instead: run `raft integration invoke --service \"Raft Feedback Admin\" --action download_feedback_transcript --param id=REPORT_ID --output PATH`."
    static let downloadURLNextAction = "Download the attachment bytes instead: GET /internal/agent-api/attachments/:attachmentId (`raft attachment view --id <attachmentId> --output <path>`)."

    public var status: UInt {
        switch self {
        case .unavailable: 404
        case .downloadURLUnavailable: 409
        case .mintFailed: 500
        }
    }

    public var errorMessage: String {
        switch self {
        case .unavailable: Self.unavailableMessage + " " + Self.unavailableNextAction
        case .downloadURLUnavailable: "This Server's file storage cannot mint download URLs."
        case .mintFailed: "Failed to mint a download URL"
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .unavailable:
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "ATTACHMENT_UNAVAILABLE"),
                OrderedJSONField("suggestedNextAction", Self.unavailableNextAction),
            ])
        case .downloadURLUnavailable:
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "download_url_unavailable"),
                OrderedJSONField("suggestedNextAction", Self.downloadURLNextAction),
            ])
        case .mintFailed:
            .object([OrderedJSONField("error", errorMessage)])
        }
    }
}

/// Domain failure for `POST /internal/agent-api/integrations/token`.
public enum AgentIntegrationTokenError: DomainError, Equatable {
    case missingAuthorization
    case invalidToken
    case invalidRequest
    case derivedFields
    case serviceRequired
    case agentInactive
    case agentNotMember
    case appUnavailable
    case grantRevoked
    case issueFailed

    public var status: UInt {
        switch self {
        case .missingAuthorization, .invalidToken: 401
        case .invalidRequest, .derivedFields, .serviceRequired: 400
        case .agentInactive, .agentNotMember, .appUnavailable, .grantRevoked: 403
        case .issueFailed: 500
        }
    }

    public var errorMessage: String {
        switch self {
        case .missingAuthorization: "Missing or invalid Authorization header"
        case .invalidToken: "Invalid or expired token"
        case .invalidRequest: "Invalid integration token request"
        case .derivedFields: "Request fields are derived from the credential"
        case .serviceRequired: "service is required"
        case .agentInactive: "Agent is not active"
        case .agentNotMember: "Agent is not a member of this Server"
        case .appUnavailable: "That App is not available on this Server"
        case .grantRevoked: "Agent access to this App has been revoked"
        case .issueFailed: "Failed to issue the App token"
        }
    }

    public var errorCode: String? {
        switch self {
        case .missingAuthorization, .invalidToken: "auth_required"
        case .invalidRequest, .derivedFields, .serviceRequired: "INVALID_REQUEST"
        case .agentInactive: "AGENT_INACTIVE"
        case .agentNotMember: "AGENT_NOT_MEMBER"
        case .appUnavailable: "APP_UNAVAILABLE"
        case .grantRevoked: "GRANT_REVOKED"
        case .issueFailed: nil
        }
    }
}
