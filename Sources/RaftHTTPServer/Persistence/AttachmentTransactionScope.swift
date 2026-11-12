import Foundation
import RaftHTTP

/// Request-scoped bounded attachment scope installed by
/// `BusinessPersistenceMiddleware` only for classified body-plane requests.
///
/// `bounded` is true exactly when the request left the outer writer. If the
/// port is missing in that state the wiring is broken and the request fails
/// closed with the exact existing 503. Non-classified requests and fixtures
/// without a persistence runtime never see `bounded`, so they keep the original
/// outer-transaction (or direct unscoped) behavior instead of a 503.
enum AttachmentTransactionScope {
    @TaskLocal static var port: (any AttachmentTransactionPort)?
    @TaskLocal static var bounded = false

    static func mode() throws -> AttachmentTransactionMode {
        if let port { return .bounded(port) }
        if bounded { throw AttachmentPersistenceUnavailable() }
        return .legacy
    }
}
