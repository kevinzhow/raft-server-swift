import Foundation
import HTTPTypes
import RaftShared

public extension HTTPReply {
    /// JSON reply with stable `Content-Type`, `Cache-Control` and
    /// `Content-Length` headers. `extraHeaders` may not override those keys.
    static func jsonValue(
        _ status: Int,
        _ value: JSONValue,
        extraHeaders: [String: String] = [:]
    ) -> HTTPReply {
        let body = (try? value.string()) ?? "{}"
        var headers: [String: String] = [
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
            "Content-Length": String(body.utf8.count),
        ]
        for (key, headerValue) in extraHeaders {
            if headers[key] == nil { headers[key] = headerValue }
        }
        return HTTPReply(status: status, headers: headers, body: body)
    }
}

/// `HTTPReply` is the value an unmigrated route returns on a denial. With
/// `Error` conformance those entry points report `Result<Success, HTTPReply>`
/// without a second error type.
extension HTTPReply: Error {}
