import Foundation
import RaftShared

// MARK: - /api/product-feedback/tickets…
//
// The ticket routes relay the Hands reporter-feedback API. The success body is
// the upstream payload, not a shape this service owns, so it is published
// through `OrderedJSON.raw` (the canonical escape hatch for a fragment the
// domain did not build). The status and the header policy travel with the
// payload because they depend on the upstream outcome.

/// `POST …/comments` request: the raw multipart text plus the client's
/// `Content-Type`. The body is not JSON, so it is forwarded to Hands unchanged
/// after the attachment-type scan.
public struct FeedbackTicketReplyRequest: Sendable, Equatable {
    public var contentType: String
    public var body: String

    public init(contentType: String, body: String) {
        self.contentType = contentType
        self.body = body
    }
}

/// A successful ticket reply relayed from Hands.
///
/// - `list`/`detail` (`200`): body re-published with the cursor re-wrapped and a
///   `Server-Timing` header.
/// - `close`/`comments` (`200` or `201`): the upstream body unchanged.
/// - `attachment` (`200`): the upstream bytes, decoded as UTF-8 like the
///   legacy reply, with the upstream `Content-Type` / `Content-Disposition`.
public struct FeedbackHandsReply: JSONBodyConvertible, Equatable {
    public let status: UInt
    public let body: String
    public let headers: ResponseHeaders

    public init(status: UInt, body: String, headers: ResponseHeaders) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    /// The upstream text, byte for byte.
    public var jsonBody: OrderedJSON { .raw(body) }

    /// Header set of every JSON conversation reply: no `X-Robots-Tag`, and the
    /// body is never cached.
    private static func jsonHeaders(serverTiming: String?) -> ResponseHeaders {
        var values = [
            "Content-Type": AppFallback.jsonContentType,
            "Cache-Control": "no-store",
        ]
        if let serverTiming { values["Server-Timing"] = serverTiming }
        return .exact(values)
    }

    /// An upstream `200`/`201` republished as is.
    static func relayed(status: UInt, body: Data) -> FeedbackHandsReply {
        FeedbackHandsReply(
            status: status,
            body: String(decoding: body, as: UTF8.self),
            headers: jsonHeaders(serverTiming: nil)
        )
    }

    /// A list/detail page with its `Server-Timing` header.
    static func timed(body: String, serverTiming: String) -> FeedbackHandsReply {
        FeedbackHandsReply(
            status: 200,
            body: body,
            headers: jsonHeaders(serverTiming: serverTiming)
        )
    }

    /// An attachment: upstream content type and disposition, never sniffed and
    /// never cached by shared caches.
    static func attachment(body: Data, upstreamHeaders: [String: String]) -> FeedbackHandsReply {
        var values = [
            "Content-Type": upstreamHeaders.first { $0.key.lowercased() == "content-type" }?.value
                ?? "application/octet-stream",
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "private, no-store",
        ]
        if let disposition = upstreamHeaders.first(where: { $0.key.lowercased() == "content-disposition" })?.value {
            values["Content-Disposition"] = disposition
        }
        return FeedbackHandsReply(
            status: 200,
            body: String(decoding: body, as: UTF8.self),
            headers: .exact(values)
        )
    }
}

/// Re-wraps one cursor member of an upstream JSON object.
///
/// The legacy handler re-serialised the whole upstream object after replacing
/// the member, with its serializer's sorted-key option. That option orders keys
/// with `localizedStandardCompare` (case-insensitive, numeric, locale aware), not
/// by code point, and escapes `/` as `\/`; both are reproduced here so the
/// republished bytes do not change. A body that is not a JSON object, lacks a
/// non-empty string member, or whose cursor cannot be wrapped is returned
/// untouched (`nil`).
///
/// Known difference: an integer literal beyond `Int64` is printed as a double
/// (`1e+20`) instead of its decimal digits.
public enum FeedbackCursorRewrite {
    public static func rewrite(
        body: Data,
        member: String,
        wrap: (String) -> String?
    ) -> String? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .object(var object) = value,
              case .string(let next)? = object[member], !next.isEmpty,
              let wrapped = wrap(next)
        else { return nil }
        object[member] = .string(wrapped)
        var out = ""
        guard render(.object(object), into: &out) else { return nil }
        return out
    }

    private static func render(_ value: JSONValue, into out: inout String) -> Bool {
        switch value {
        case .object(let object):
            out += "{"
            let keys = object.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                guard scalar(key, into: &out) else { return false }
                out += ":"
                guard let member = object[key], render(member, into: &out) else { return false }
            }
            out += "}"
            return true
        case .array(let array):
            out += "["
            for (index, element) in array.enumerated() {
                if index > 0 { out += "," }
                guard render(element, into: &out) else { return false }
            }
            out += "]"
            return true
        case .string(let string):
            return scalar(string, into: &out)
        case .number(let number):
            return scalar(number, into: &out)
        case .integer(let integer):
            out += String(integer)
            return true
        case .bool(let bool):
            out += bool ? "true" : "false"
            return true
        case .null:
            out += "null"
            return true
        }
    }

    /// One JSON scalar token through the standard encoder (escapes `/`).
    private static func scalar<T: Encodable>(_ value: T, into out: inout String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        out += String(decoding: data, as: UTF8.self)
        return true
    }
}
