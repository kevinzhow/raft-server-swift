import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

enum HumanAdmissionRoutePolicy: Sendable, Equatable {
    case verifiedProfile
    case profileOnly
    // A later middleware owns whole-prefix flex + first scope, then the
    // human-only gate after serving-router fallthrough. Never gate here.
    case legacyAttachment
}

/// Node app.ts mount order, including routes that run before the broad mounts.
/// No policy is inferred from a generic /api prefix or from credential spelling.
enum HumanAdmissionPolicy {
    static func requirement(
        method: HTTPRequest.Method, path rawPath: String,
        nativeNotificationsEnabled: Bool = true
    ) -> HumanAdmissionRoutePolicy? {
        guard method != .options else { return nil }
        let read = method == .get || method == .head
        // Express string mounts are case-insensitive and accept a trailing slash.
        // Keep internal empty segments: /api//servers is not /api/servers.
        let lowered = rawPath.lowercased()
        let path = lowered.hasSuffix("/") ? String(lowered.dropLast()) : lowered
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        if path == "/api/auth/accept-invite", method == .post { return .profileOnly }
        // The pinned translation mount is an anchored regular expression.
        if rawPath == "/api/message-translations:batch", method == .post { return .verifiedProfile }
        if parts.count == 6, parts[0].isEmpty, parts[1] == "api", parts[2] == "public",
           parts[3] == "servers", !parts[4].isEmpty, parts[5] == "join-as-guest", method == .post {
            return .verifiedProfile
        }

        if read, ["/api/mcp/oauth/callback", "/api/mcp/oauth/client-metadata"].contains(path) {
            return nil
        }
        if mounted(path, at: "/api/attachments") {
            return attachmentRequirement(method: method, path: path)
        }
        let mounts = [
            "/api/servers", "/api/feature-flags", "/api/channels", "/api/read-mutations",
            "/api/messages", "/api/v2/messages", "/api/raftbench", "/api/agents",
            "/api/billing", "/api/tasks", "/api/reminders", "/api/share-artifacts",
            "/api/integration-invites", "/api/integrations", "/api/actions",
            "/api/product-events", "/api/mcp", "/api/provider-connections",
            "/api/agent-runtime-providers", "/api/product-feedback",
        ]
        if mounts.contains(where: { mounted(path, at: $0) }) { return .verifiedProfile }

        switch (method, path) {
        case (.post, "/api/slack-bridge/oauth/start"),
             (.get, "/api/slack-bridge/provisioning"), (.head, "/api/slack-bridge/provisioning"),
             (.post, "/api/slack-bridge/provisioning/connect"),
             (.put, "/api/slack-bridge/provisioning/channel-pairs"),
             (.delete, "/api/slack-bridge/provisioning/channel-pairs"),
             (.post, "/api/slack-bridge/provisioning/disconnect"),
             (.post, "/api/slack-bridge/provisioning/preflight"),
             (.post, "/api/slack-bridge/provisioning/enable"):
            return .verifiedProfile
        case (.post, "/api/push/subscribe"), (.delete, "/api/push/subscribe"),
             (.get, "/api/push/delivery-status"), (.head, "/api/push/delivery-status"),
             (.post, "/api/push/registrations"), (.post, "/api/push/test"):
            return .verifiedProfile
        default: break
        }
        if parts.count == 5, parts[0].isEmpty, parts[1] == "api", parts[2] == "push",
           parts[3] == "registrations", !parts[4].isEmpty, method == .delete {
            return .verifiedProfile
        }
        if nativeNotificationsEnabled {
            if method == .post && path == "/api/notifications/enrollment-grants" { return .verifiedProfile }
            if read && path == "/api/notifications/devices" { return .verifiedProfile }
            if parts.count == 5, parts[0].isEmpty, parts[1] == "api", parts[2] == "notifications",
               parts[3] == "devices", !parts[4].isEmpty, method == .delete {
                return .verifiedProfile
            }
        }
        if read && path == "/api/announcements/active" { return .verifiedProfile }
        if parts.count == 5, parts[0].isEmpty, parts[1] == "api", parts[2] == "announcements",
           !parts[3].isEmpty, parts[4] == "dismiss", method == .post {
            return .verifiedProfile
        }
        return nil
    }

    private static func mounted(_ path: String, at prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    private static func attachmentRequirement(method: HTTPRequest.Method, path: String) -> HumanAdmissionRoutePolicy? {
        let prefix = "/api/attachments/"
        guard path.hasPrefix(prefix) else { return .legacyAttachment }
        let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let read = method == .get || method == .head
        // app.ts:559's narrow upload router precedes flex-auth downloads.
        if read && parts == ["upload-capabilities"] { return .verifiedProfile }
        if read && parts.count == 3 && parts[0] == "upload-sessions" && !parts[1].isEmpty && parts[2] == "active" {
            return .verifiedProfile
        }
        if parts.first == "upload-sessions" {
            if method == .post && parts.count == 1 { return .verifiedProfile }
            if parts.count >= 2,
               parts[1].wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) != nil {
                if parts.count == 2 && (read || method == .delete) { return .verifiedProfile }
                if parts.count == 3 && parts[2] == "complete" && method == .post { return .verifiedProfile }
            }
        }
        // These are the actual public-router matches, not every attachment GET.
        // They retain JWT/query/machine/HTML-preview flex authentication downstream.
        if read && parts.count == 1 && !parts[0].isEmpty { return nil }
        if read && parts.count == 2 && !parts[0].isEmpty
            && ["url", "preview", "html-preview-url", "html-preview"].contains(parts[1]) { return nil }
        if method == .post && parts == ["urls"] { return nil }
        return .legacyAttachment
    }
}

/// Installed inside business restoration and before body/server-scope decoding.
/// All decisions read the same typed services as the routed request handlers.
struct HumanAdmissionMiddleware: Middleware {
    let auth: AuthCoreService
    let nativeNotifications: NativeNotificationsService

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        let enabled = nativeNotifications.deploymentConfiguration.enabled
        let raw = HumanAdmissionPolicy.requirement(
            method: request.method, path: request.url.path, nativeNotificationsEnabled: enabled)
        let matched = RouterMountBoundaryPolicy.admissionPath(for: request).flatMap {
            HumanAdmissionPolicy.requirement(method: request.method, path: $0, nativeNotificationsEnabled: enabled)
        }
        // A later encoded constant must not weaken the serving route's gate.
        // Keep the raw policy as well, including its earlier attachment phases.
        let policies = [raw, matched].compactMap { $0 }
        let requirement: HumanAdmissionRoutePolicy?
        if policies.contains(.verifiedProfile) { requirement = .verifiedProfile }
        else if policies.contains(.profileOnly) { requirement = .profileOnly }
        else if policies.contains(.legacyAttachment) { requirement = .legacyAttachment }
        else { requirement = nil }
        guard let requirement else { return try await next.respond(to: request) }
        let humanRequirement: HumanAdmissionRequirement
        switch requirement {
        case .verifiedProfile: humanRequirement = .verifiedProfile
        case .profileOnly: humanRequirement = .profileOnly
        case .legacyAttachment: return try await next.respond(to: request)
        }
        do {
            _ = try auth.admitHuman(authorization: request.headers[.authorization], requirement: humanRequirement)
        } catch let error as HumanAdmissionError {
            var refusal = RaftHTTPServer.respond(
                status: error.status, headers: error.errorHeaders,
                rawJSON: error.publishedErrorBody.render()
            )
            if request.method == .head {
                let length = refusal.headers[.contentLength]
                refusal.body = .init(string: "")
                refusal.headers[.contentLength] = length
            }
            return refusal
        }
        return try await next.respond(to: request)
    }
}

/// app.ts installs its API freshness default before authenticated route mounts.
/// Installed after early body limits and before the JSON error boundary.
/// An outer wrapper also covers refusals produced by that boundary; explicit
/// immutable/public/route-specific cache policies remain authoritative.
struct DefaultAPIResponseHeadersMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        var response = try await next.respond(to: request)
        let lowered = request.url.path.lowercased()
        let path = lowered.hasSuffix("/") ? String(lowered.dropLast()) : lowered
        let isAPI = path == "/api" || path.hasPrefix("/api/")
            || path == "/internal" || path.hasPrefix("/internal/")
        // These exact POST route phases precede Node's default-cache mount.
        // Leave their header policy to the early handlers for every status;
        // similarly named GET/HEAD and deeper paths use the ordinary default.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let isEarlyControl = parts.count == 8 && parts[0].isEmpty
            && parts[1] == "internal" && parts[2] == "computer"
            && parts[3] == "agent-migrations" && parts[4] == "by-id"
            && !parts[5].isEmpty && parts[6] == "resumable" && parts[7] == "control"
        let isEarlyRoute = request.method == .post
            && (path == "/internal/machine/scope-attestation" || isEarlyControl)
        if isAPI && !isEarlyRoute && response.headers[.cacheControl] == nil {
            response.headers[.cacheControl] = "private, no-store"
        }
        return response
    }
}
