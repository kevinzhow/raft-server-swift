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

/// `POST /api/feature-flags/evaluate` request body.
///
/// `buildNumber` stays a `String` because the published contract accepts the
/// decimal string clients send; a numeric build number does not decode and the
/// route falls back to the raw body, which keeps the existing number handling.
public struct FeatureFlagsEvaluateDTO: Codable, Sendable, Equatable {
    public var keys: [String]?
    public var key: String?
    public var serverId: String?
    public var platform: String?
    public var os: String?
    public var appVersion: String?
    public var buildNumber: String?
    public var buildType: String?

    public init(
        keys: [String]? = nil,
        key: String? = nil,
        serverId: String? = nil,
        platform: String? = nil,
        os: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        buildType: String? = nil
    ) {
        self.keys = keys
        self.key = key
        self.serverId = serverId
        self.platform = platform
        self.os = os
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.buildType = buildType
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
