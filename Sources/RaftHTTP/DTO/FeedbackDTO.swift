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
