import Foundation
import RaftShared

/// The shared reader for the `pendingLinkToken` request member.
///
/// Pinned `routes/auth.ts:168-177` reads `body.pendingLinkToken` on the routes
/// that complete a mobile OAuth flow, complete a provider sign-in, log in, and
/// cancel a pending link:
///
/// - `undefined`, `null` or `""` is "not sent";
/// - any other non-string, or a string over 256 UTF-16 units, is the published
///   `{"code":"pending_link_token_invalid","error":"pendingLinkToken must be a string"}`;
/// - a valid string is the token.
public enum PendingLinkToken: Sendable, Equatable {
    case absent
    case token(String)
    case invalid

    public static func parse(_ body: JSONValue?) -> PendingLinkToken {
        guard let body, case .object(let fields) = body else { return .absent }
        guard let value = fields["pendingLinkToken"] else { return .absent }
        switch value {
        case .null:
            return .absent
        case .string(let text):
            if text.isEmpty { return .absent }
            return text.utf16.count > 256 ? .invalid : .token(text)
        case .object, .array, .number, .integer, .bool:
            return .invalid
        }
    }

    /// `{"code":"pending_link_token_invalid","error":"pendingLinkToken must be a string"}`
    public static var invalidBody: OrderedJSON {
        .object([
            OrderedJSONField("code", "pending_link_token_invalid"),
            OrderedJSONField("error", "pendingLinkToken must be a string"),
        ])
    }

    /// `{"code":"pending_link_token_invalid","error":"pendingLinkToken is required"}`
    public static var requiredBody: OrderedJSON {
        .object([
            OrderedJSONField("code", "pending_link_token_invalid"),
            OrderedJSONField("error", "pendingLinkToken is required"),
        ])
    }
}
