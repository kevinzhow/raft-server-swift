import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

public struct AttachmentFlexContext: Authenticatable {
    public let admission: AttachmentFlexAdmission
}

/// Express's upload-session router runs before the whole-prefix flex mount.
/// Public-router terminal matches are separate from preview authentication.
enum AttachmentFlexRoutePolicy {
    static func relativePath(_ path: String) -> String? {
        let prefix = "/api/attachments"
        let lowered = path.lowercased()
        guard lowered == prefix || lowered.hasPrefix(prefix + "/") else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    static func isNarrow(method: HTTPRequest.Method, path: String) -> Bool {
        HumanAdmissionPolicy.requirement(method: method, path: path) == .verifiedProfile
    }

    static func isServing(method: HTTPRequest.Method, relativePath: String) -> Bool {
        let path = relativePath.lowercased()
        let withoutTrailingSlash = path.hasSuffix("/") ? String(path.dropLast()) : path
        let withoutLeadingSlash = withoutTrailingSlash.hasPrefix("/")
            ? String(withoutTrailingSlash.dropFirst()) : withoutTrailingSlash
        let parts = withoutLeadingSlash.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let read = method == .get || method == .head
        if read && parts.count == 1 && !parts[0].isEmpty { return true }
        if read && parts.count == 2 && !parts[0].isEmpty
            && ["url", "preview", "html-preview-url", "html-preview"].contains(parts[1]) { return true }
        return method == .post && parts == ["urls"]
    }
}

/// Installed after the API cache boundary and existing CORS handling. Never
/// promotes a query token, a preview capability, or a machine key to the human
/// Authorization header used by the later write mount.
struct AttachmentFlexAdmissionMiddleware: Middleware {
    let lifecycle: AgentsLifecycleService

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        guard let relativePath = AttachmentFlexRoutePolicy.relativePath(request.url.path),
              !AttachmentFlexRoutePolicy.isNarrow(method: request.method, path: request.url.path) else {
            return try await next.respond(to: request)
        }
        let input = AttachmentFlexRequest(
            authorization: request.headers[.authorization],
            queryToken: AttachmentQueryScalars.value(request.url.query, named: "token"),
            previewToken: AttachmentQueryScalars.value(request.url.query, named: "previewToken"),
            headerServerId: request.headers[HTTPField.Name("X-Server-Id")!],
            queryServerId: AttachmentQueryScalars.value(request.url.query, named: "serverId"),
            relativePath: relativePath
        )
        let authorization = request.headers[.authorization]
        let headerServerId = request.headers[HTTPField.Name("X-Server-Id")!]
        let serving = AttachmentFlexRoutePolicy.isServing(method: request.method, relativePath: relativePath)
        do {
            // The admission and the legacy write gate are one committed phase
            // for a classified request. A scheduled non-domain error is rethrown
            // to the JSON boundary; typed refusals keep their exact bytes.
            let transaction = try AttachmentTransactionScope.mode()
            let admission = try await transaction.committedAsyncValue {
                let admission = try await lifecycle.admitAttachmentFlex(input)
                if !serving {
                    _ = try lifecycle.authorizeLegacyAttachmentWrite(
                        authorization: authorization,
                        headerServerId: headerServerId,
                        flexAdmission: admission
                    )
                }
                return admission
            }
            // Request-authentication mutation happens only after the committed
            // phase; it is not part of the durable admission.
            request.auth.login(AttachmentFlexContext(admission: admission))
        } catch let error as any DomainError {
            var response = RaftHTTPServer.respond(status: error.status, headers: error.errorHeaders,
                rawJSON: error.publishedErrorBody.render())
            if request.method == .head {
                let length = response.headers[.contentLength]
                response.body = .init(string: "")
                response.headers[.contentLength] = length
            }
            return response
        }
        return try await next.respond(to: request)
    }

}

/// Match Express scalar queries: duplicate values are arrays, not bearer tokens.
enum AttachmentQueryScalars {
    static func value(_ query: String?, named name: String) -> String? {
        guard let query, let items = URLComponents(string: "http://localhost/?" + query)?.queryItems else { return nil }
        let matches = items.filter { $0.name == name }
        guard matches.count == 1 else { return nil }
        return matches[0].value ?? ""
    }
}
