import Foundation
import HTTPTypes
import RaftHTTP

/// Exact raw-path classifier for the selected attachment body plane.
///
/// Only these four shapes leave the outer business writer and use the bounded
/// transaction port. Every other attachment shape (upload sessions, `url`,
/// `urls`, `html-preview-url`, comments, malformed/non-UUID ids, aliases,
/// trailing or doubled slashes, internal agent/machine paths and public
/// attachments) keeps the legacy FIFO path and its exact errors. A false
/// negative only keeps the old serialization; a false positive is prevented by
/// exact segment counts plus `ServerScope.isUUID`.
///
/// The path is the raw request target: no percent decoding and no route
/// reconstruction. `RouterMountBoundaryMiddleware` has already rejected
/// constant-prefix case/alias mismatches before this classifier runs. HEAD is
/// accepted because Vapor forwards it to the matching GET route.
enum AttachmentBodyPlanePolicy {
    static func matches(method: HTTPRequest.Method, path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts[0].isEmpty,
              parts[1] == "api", parts[2] == "attachments" else {
            return false
        }
        if method == .post {
            return parts.count == 4 && parts[3] == "upload"
        }
        guard method == .get || method == .head else { return false }
        if parts.count == 4 {
            return ServerScope.isUUID(parts[3])
        }
        guard parts.count == 5, parts[4] == "preview" || parts[4] == "html-preview" else {
            return false
        }
        return ServerScope.isUUID(parts[3])
    }
}
