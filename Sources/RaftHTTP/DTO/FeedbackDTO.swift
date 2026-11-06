import Foundation

// MARK: - Product feedback DTOs
//
// Wire shapes for the upstream Hands product-feedback API. The field order is
// declaration order: `JSONEncoder` keeps it, matching the upstream bodies the
// Node handlers emit (`{"id":…,"status":…}`, `{"error":…,"code":…}`). The
// feedback routes still own their status/header projection; these structs only
// replace hand-built JSON strings.

/// `201` body of `POST /api/product-feedback` and the upstream Hands success
/// payload.
public struct FeedbackSubmissionResponse: Codable, Sendable, Equatable {
    public var id: String
    public var status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

/// `POST /api/product-feedback/tickets/:ticketId/close` request body.
public struct FeedbackTicketCloseRequest: Codable, Sendable, Equatable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

// MARK: - Notification, push and feature-flag request DTOs
//
// The route collections decode these shapes first and fall back to the raw
// body when a client sends something the typed decoder rejects, so the
// existing body validators stay the single source of truth for the published
// status/JSON. Optional fields keep a partially populated body decodable; the
// service still rejects whatever it needs to reject.

/// `POST /api/notifications/credentials/rotate` request body. The proof is the
/// device key over the current credential.
public struct RotateNotificationCredentialDTO: Codable, Sendable, Equatable {
    public var proof: String?

    public init(proof: String? = nil) {
        self.proof = proof
    }
}

/// `POST /api/notifications/enrollment-exchanges` request body. One grant mints
/// one credential; the proof is the device key over the enrollment transcript.
public struct EnrollmentExchangeDTO: Codable, Sendable, Equatable {
    public var grant: String?
    public var proof: String?

    public init(grant: String? = nil, proof: String? = nil) {
        self.grant = grant
        self.proof = proof
    }
}

/// `POST /api/notifications/enrollment-grants` request body.
///
/// `attestation` is carried verbatim so a re-encoded typed request keeps the
/// exact evidence the raw-body attestation check reads.
public struct EnrollmentGrantRequestDTO: Codable, Sendable, Equatable {
    public var appId: String?
    public var protocolVersion: Int?
    public var appVersion: String?
    public var releaseChannel: String?
    public var appInstanceId: String?
    public var publicKey: String?
    public var nonce: String?
    public var attestation: String?

    public init(
        appId: String? = nil,
        protocolVersion: Int? = nil,
        appVersion: String? = nil,
        releaseChannel: String? = nil,
        appInstanceId: String? = nil,
        publicKey: String? = nil,
        nonce: String? = nil,
        attestation: String? = nil
    ) {
        self.appId = appId
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.releaseChannel = releaseChannel
        self.appInstanceId = appInstanceId
        self.publicKey = publicKey
        self.nonce = nonce
        self.attestation = attestation
    }
}

/// One canonical encoder call for the feedback DTOs so the feature and the
/// service cannot drift on formatting. `JSONEncoder` is a mutable value, so a
/// fresh instance is created per call and never shared across concurrent
/// requests.
public enum FeedbackJSONCoding {
    public static func string<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
