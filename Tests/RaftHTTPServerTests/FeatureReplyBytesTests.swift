import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import Testing
import TestSupport
import Vapor
import VaporTesting
@testable import RaftHTTPServer

/// Byte-exact pins for Feature/middleware replies, including the complete
/// Node app's outer auth and default-cache phases before the routed handlers.
private func shot(_ response: ClientResponse, excludingDefaultAPIHeader: Bool = false) -> String {
    let headers = response.headers
        .filter { !excludingDefaultAPIHeader || $0.name != .cacheControl }
        .map { "\($0.name.rawName.lowercased()): \($0.value)" }
        .sorted()
        .joined(separator: "\n")
    return "\(response.status.code)\n\(headers)\n\n\(response.body.string ?? "<nil>")"
}

private func withDefaultApp(
    accounts: EmailLoginDirectory = EmailLoginDirectory(),
    services build: ((EmailLoginDirectory) -> FallbackServices)? = nil,
    _ body: @escaping (any TestClient) async throws -> Void
) async throws {
    try await withApp { app in
        configure(app, services: build?(accounts) ?? FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in try await body(client) }
    }
}

@Suite(.serialized)
struct FeatureReplyBytesTests {
    @Test func featureReplies() async throws {
        try await withDefaultApp { client in
            var out: [String] = []
            for path in [
                "/api/avatars/pixel/a.png", "/api/avatars/pixel/%21.svg", "/api/avatars/pixel/eA.svg", "/api/avatars/pixel/Y2F0.svg",
            ] {
                out.append("GET \(path)\n" + shot(try await client.get(URI(string: path))))
            }
            for path in ["/api/servers/abc/public-visibility"] {
                out.append("GET \(path)\n" + shot(try await client.get(URI(string: path))))
            }
            for path in ["/api/servers/abc/public-guest-join", "/api/servers/abc/public-visibility", "/api/servers/abc/public-search"] {
                out.append("PATCH \(path)\n" + shot(try await client.send(.patch, to: URI(string: path))))
            }
            for path in ["/api/channels/activity/snapshot", "/api/channels/activity/difference"] {
                out.append("GET \(path)\n" + shot(try await client.get(URI(string: path))))
            }
            out.append("POST migration-export\n" + shot(try await client.send(.post, to: "/api/actions/migration-export")))
            for path in ["/oidc/BAD_SCOPE/.well-known/openid-configuration", "/oidc/nope/.well-known/openid-configuration"] {
                out.append("GET \(path)\n" + shot(try await client.get(URI(string: path))))
            }
            for path in ["/api/attachments/abc/url?previewToken=x", "/api/attachments/abc?previewToken=x", "/api/attachments/abc/html-preview-url?previewToken=x"] {
                out.append("GET \(path)\n" + shot(try await client.get(URI(string: path))))
            }
            out.append("POST attachments/upload\n" + shot(try await client.send(.post, to: "/api/attachments/upload")))
            out.append("POST agent-api/upload\n" + shot(try await client.send(.post, to: "/internal/agent-api/upload")))
            assertReplies(out, expected: featureReplySnapshots)
        }
    }

    @Test func knowledgeReplies() async throws {
        let accounts = EmailLoginDirectory()
        let owner = "11111111-1111-4111-8111-111111111641"
        let serverId = "33333333-3333-4333-8333-333333333641"
        accounts.addAccount(id: owner, email: "k-owner@slock.test", password: "password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: serverId, slug: "k-bytes", name: "K", ownerId: owner)
        let agent = accounts.oauth.createAgent(serverId: serverId, name: "KBot", runtime: "claude")
        let key = accounts.mintAgentCredential(agentId: agent, scopes: ["knowledge"], name: "k")
        let readOnly = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "r")
        let intent = "Help the user accomplish their Raft workflow"
        let reason = "Need the relevant Manual guidance at this point"
        var out: [String] = []
        try await withDefaultApp(accounts: accounts) { client in
            func get(_ path: String, key: String?, cli: Bool = true, caps: Bool = true) async throws -> String {
                var headers = HTTPFields()
                if let key { headers[.authorization] = "Bearer \(key)" }
                if cli { headers[HTTPField.Name("X-Raft-Client")!] = "cli" }
                if caps { headers[HTTPField.Name("X-Raft-Client-Capabilities")!] = "manual-context-v1" }
                let res = try await client.get(URI(string: path), headers: headers)
                // Keep the established body/header digests strict while asserting
                // the newly restored app-level header independently.
                #expect(res.headers[.cacheControl] == "private, no-store")
                var text = shot(res, excludingDefaultAPIHeader: true)
                if text.utf8.count > 700 {
                    let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                    text = "<\(text.utf8.count) bytes sha256 \(digest)>\n" + text.prefix(400)
                }
                return text
            }
            let ctx = "intent=\(intent.replacingOccurrences(of: " ", with: "%20"))&reason=\(reason.replacingOccurrences(of: " ", with: "%20"))"
            let base = "/internal/agent-api/knowledge"
            out.append("noauth\n" + (try await get("\(base)?topic=slock-home&\(ctx)", key: nil)))
            out.append("readonly\n" + (try await get("\(base)?topic=slock-home&\(ctx)", key: readOnly)))
            out.append("nosource\n" + (try await get("\(base)?topic=slock-home&\(ctx)", key: key, cli: false)))
            out.append("notopic\n" + (try await get("\(base)?\(ctx)", key: key)))
            out.append("noIntent\n" + (try await get("\(base)?topic=slock-home", key: key)))
            out.append("badReason\n" + (try await get("\(base)?topic=slock-home&intent=\(intent.replacingOccurrences(of: " ", with: "%20"))&reason=short", key: key)))
            out.append("turnMismatch\n" + (try await get("\(base)?topic=slock-home&\(ctx)&turn_id=a", key: key)))
            out.append("get ok\n" + (try await get("\(base)?topic=slock-home&\(ctx)", key: key)))
            out.append("get legacy\n" + (try await get("\(base)?topic=slock-home", key: key, caps: false)))
            out.append("get missing\n" + (try await get("\(base)?topic=nothing-here-zzz&\(ctx)", key: key)))
            out.append("get missing legacy\n" + (try await get("\(base)?topic=nothing-here-zzz", key: key, caps: false)))
            out.append("search noquery\n" + (try await get("\(base)/search?\(ctx)", key: key)))
            out.append("search badscope\n" + (try await get("\(base)/search?query=tasks&scope=x&\(ctx)", key: key)))
            out.append("search ok\n" + (try await get("\(base)/search?query=tasks&\(ctx)", key: key)))
            out.append("search recipes\n" + (try await get("\(base)/search?query=tasks&scope=recipes&\(ctx)", key: key)))
            out.append("search miss\n" + (try await get("\(base)/search?query=zzqqxx&\(ctx)", key: key)))
            out.append("search miss scope\n" + (try await get("\(base)/search?query=zzqqxx&scope=recipes&\(ctx)", key: key, caps: false)))
            out.append("search lang\n" + (try await get("\(base)/search?query=%E4%BD%A0%E5%A5%BD%E4%B8%96%E7%95%8C&\(ctx)", key: key)))
        }
        assertReplies(out, expected: knowledgeReplySnapshots)
    }

    @Test func requestBodyPoliciesAndAuthorizationOrder() async throws {
        try await withDefaultApp { client in
            func post(_ path: String, _ body: String?, contentType: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.contentType] = contentType
                return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
            }

            // These raw-JSON auth routes accept JSON under every media type.
            let credentials = #"{"email":"absent@slock.test","password":"wrong"}"#
            let login = shot(try await post("/api/auth/login", credentials, contentType: "application/json"))
            #expect(login.hasPrefix("401\n"))
            for mediaType: String? in [nil, "text/plain", "application/x-www-form-urlencoded"] {
                #expect(shot(try await post("/api/auth/login", credentials, contentType: mediaType)) == login)
            }
            let malformed = shot(try await post("/api/auth/login", "{"))
            #expect(malformed.hasPrefix("400\n"))
            for body: String? in [nil, "", "  \n", "null", "email=absent%40slock.test&password=wrong"] {
                #expect(shot(try await post("/api/auth/login", body, contentType: "application/x-www-form-urlencoded")) == malformed)
            }
            // A valid JSON non-object root reaches the schema (the raw-JSON
            // tolerance above decodes it) and publishes the zod object issue,
            // not the empty-object refusal a malformed body gets.
            let notObject = shot(try await post("/api/auth/login", "[]", contentType: "application/x-www-form-urlencoded"))
            #expect(notObject.hasPrefix("400\n"))
            #expect(notObject.hasSuffix(#"{"error":"Invalid email login body","code":"email_login_body_invalid","issues":[{"path":"","message":"Invalid input: expected object, received array"}]}"#))

            // Email verification deliberately uses only the registered decoder.
            let missingToken = shot(try await post("/api/auth/verify-email", nil))
            #expect(missingToken.hasSuffix(#"{"error":"Token is required"}"#))
            let token = #"{"token":"unknown"}"#
            #expect(shot(try await post("/api/auth/verify-email", token, contentType: "text/plain")) == missingToken)
            #expect(shot(try await post("/api/auth/verify-email", token, contentType: "application/json"))
                .hasSuffix(#"{"error":"Invalid or expired verification token"}"#))

            // Body refusals must not precede the route's authentication policy.
            for path in [
                "/api/channels/missing/resume-all-agents",
                "/api/channels/threads/follow",
                "/internal/computer/agent-migrations/by-id/missing/arrived",
                "/api/product-events/onboarding-wizard",
            ] {
                let unauthenticated = shot(try await post(path, nil))
                #expect(unauthenticated.hasPrefix("401\n"))
                for body in ["{", "[]", "null", "{}", "  \n"] {
                    #expect(shot(try await post(path, body, contentType: "text/plain")) == unauthenticated)
                }
            }
        }
    }

    @Test func blankResumeAndLenientThreadFields() async throws {
        let accounts = EmailLoginDirectory()
        let owner = "11111111-1111-4111-8111-111111111622"
        let serverId = "33333333-3333-4333-8333-333333333666"
        let messageId = "44444444-4444-4444-8444-444444444666"
        accounts.addAccount(id: owner, email: "body-policy@slock.test", password: "password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: serverId, slug: "body-policy", name: "Body", ownerId: owner)
        let channel = accounts.oauth.createChannel(serverId: serverId, name: "parent", creatorUserId: owner)
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: owner)
        accounts.addChannelMessageForTesting(id: messageId, channelId: channel, content: "parent", senderId: owner)
        let thread = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: messageId)
        accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: owner, kind: "thread", parentChannelId: channel, parentMessageId: messageId)
        let token = accounts.mintAccessTokenForTesting(userId: owner)
        try await withDefaultApp(accounts: accounts) { client in
            func post(_ path: String, _ body: String?, contentType: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                headers[.contentType] = contentType
                return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
            }
            let path = "/api/channels/\(channel)/resume-all-agents"
            let empty = shot(try await post(path, "{}", contentType: "application/json"))
            #expect(empty.hasPrefix("200\n"))
            for body: String? in [nil, "", " \n\t", "{}"] {
                #expect(shot(try await post(path, body, contentType: "text/plain")) == empty)
            }
            for body in ["{", "[]", "null"] {
                let response = try await post(path, body, contentType: "application/json")
                #expect(response.status == .badRequest)
                #expect(response.body.string == #"{"error":"Invalid resume request"}"#)
            }
            for mediaType: String? in [nil, "application/json", "text/plain"] {
                let response = try await post(
                    "/api/channels/threads/follow",
                    #"{"threadChannelId":42,"parentMessageId":"\#(messageId)"}"#,
                    contentType: mediaType
                )
                #expect(response.status == .ok)
                #expect(response.body.string == "{\"ok\":true,\"threadChannelId\":\"\(thread)\"}")
            }
        }
    }

    @Test func middlewareReplies() async throws {
        var out: [String] = []
        // experimental gate
        let accounts = EmailLoginDirectory()
        accounts.setExperimentalSurfacesDisabledForTesting(true)
        try await withDefaultApp(accounts: accounts) { client in
            out.append("GET gate agent-api\n" + shot(try await client.get("/internal/agent-api")))
            out.append("POST gate computer\n" + shot(try await client.send(.post, to: "/internal/computer/x")))
        }
        // error boundary
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}))
            app.get("boom") { _ -> Response in
                struct Boom: Error {}
                throw Boom()
            }
            try await app.testing { client in
                let masked = shot(try await client.get("/boom"))
                    .replacingOccurrences(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", with: "<uuid>", options: .regularExpression)
                out.append("GET boom\n" + masked)
            }
        }
        // body limits
        let owner = "11111111-1111-4111-8111-111111111636"
        let limits = EmailLoginDirectory()
        limits.addAccount(id: owner, email: "bytes-owner@slock.test", password: "password123")
        limits.markEmailVerified(userId: owner)
        limits.oauth.addOwnedServer(id: "33333333-3333-4333-8333-333333333676", slug: "bytes", name: "Bytes", ownerId: owner)
        let machineId = limits.registerMachine(serverId: "33333333-3333-4333-8333-333333333676", userId: owner, name: "bytes-machine")
        let machineKey = limits.machineAPIKey(machineId: machineId) ?? ""
        limits.setScopeAttestationSecretForTesting("scope-body-secret")
        let attach = try? limits.computersFleet.attachComputer(
            authorization: "Bearer \(limits.mintAccessTokenForTesting(userId: owner))",
            request: ComputerAttachRequest(serverSlug: "bytes", name: "bytes-computer")
        )
        let computerKey = attach?.apiKey ?? ""
        func post(_ client: any TestClient, _ path: String, bytes: Int, key: String?) async throws -> String {
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            if let key { headers[.authorization] = "Bearer \(key)" }
            let res = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                request.body = .init(string: "{\"a\":\"" + String(repeating: "x", count: bytes) + "\"}")
            }
            return shot(res)
        }
        try await withDefaultApp(accounts: limits) { client in
            out.append("scope unauth\n" + (try await post(client, "/internal/machine/scope-attestation", bytes: 1_100_000, key: nil)))
            out.append("scope machine\n" + (try await post(client, "/internal/machine/scope-attestation", bytes: 1_100_000, key: machineKey)))
            out.append("control unauth\n" + (try await post(client, "/internal/computer/agent-migrations/by-id/m1/resumable/control", bytes: 700_000, key: nil)))
            out.append("control computer\n" + (try await post(client, "/internal/computer/agent-migrations/by-id/m1/resumable/control", bytes: 700_000, key: computerKey)))
            out.append("global\n" + (try await post(client, "/api/auth/login", bytes: 180_000, key: nil)))
        }
        // public search service refusals
        let token = "current-token-0123456789abcdef"
        let sha = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let source = StaticKeys([PublicSearchServiceKey(keyId: "k-current", sha256: sha)])
        let directory = PublicServerDirectory()
        directory.rolloutEnabled = true
        directory.searchIndexEnabled = true
        let seed = directory.addServer(id: "server", name: "S", slug: "s-svc", ownerId: "o", ownerToken: "t", publiclyVisible: true, channels: [])
        let bucket = PublicSearchMemoryBucketStore()
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                publicSearch: directory.projectedCatalog(), publicServerDirectory: directory,
                publicSearchServiceKeySource: source, publicSearchServiceBucket: bucket,
                publicSearchServiceLimits: PublicSearchServiceLimits(environment: ["RAFT_LANDING_SERVICE_RATE_PER_MINUTE": "1", "RAFT_LANDING_SERVICE_MAX_IN_FLIGHT": "4"])
            ))
            try await app.testing { client in
                let url = "/api/public/search/servers/\(seed!.serverPublicId)"
                func get(_ authorization: String?) async throws -> String {
                    var headers = HTTPFields()
                    if let authorization { headers[HTTPField.Name("Authorization")!] = authorization }
                    return shot(try await client.get(URI(string: url), headers: headers))
                }
                out.append("search bad key\n" + (try await get("Raft-Service v1 k-nope.\(token)")))
                out.append("search ok\n" + (try await get("Raft-Service v1 k-current.\(token)")).prefix(120))
                out.append("search limited\n" + (try await get("Raft-Service v1 k-current.\(token)")))
                source.set([])
                out.append("search unavailable\n" + (try await get("Raft-Service v1 k-current.\(token)")))
                out.append("search method\n" + shot(try await client.send(.post, to: URI(string: url))))
            }
        }
        assertReplies(out, expected: middlewareReplySnapshots)
    }
}

@Test func globalDeclaredJSONLimitPrecedesAccountAdmissionAndCacheButNotSpecialCredentials() async throws {
    try await withDefaultApp { client in
        func post(_ path: String, count: Int) async throws -> ClientResponse {
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                request.body = .init(string: "{\"padding\":\"" + String(repeating: "x", count: count) + "\"}")
            }
        }
        // An anonymous protected endpoint must hit the global parser limit
        // before account admission, store access or the raw API cache mount.
        for path in ["/api/auth/login", "/api/servers", "/api/%73ervers"] {
            let denied = try await post(path, count: 180_000)
            #expect(denied.status == .contentTooLarge)
            #expect(denied.body.string == #"{"error":"Request body is too large","code":"request_body_too_large"}"#)
            #expect(denied.headers[.contentLength] == "69")
            #expect(denied.headers[.contentType] == "application/json")
            #expect(denied.headers[.cacheControl] == nil)
        }
        // These credential-gated parsers remain within the existing business
        // boundary and retain their earlier auth-required response.
        for path in ["/internal/machine/scope-attestation", "/internal/computer/agent-migrations/by-id/m1/resumable/control"] {
            let denied = try await post(path, count: 1_100_000)
            #expect(denied.status == .unauthorized)
            #expect(denied.body.string == #"{"error":"Unauthorized","code":"auth_required"}"#)
            #expect(denied.headers[.contentLength] == "47")
            #expect(denied.headers[.cacheControl] == nil)
        }
    }
}

private final class StaticKeys: PublicSearchServiceKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [PublicSearchServiceKey]
    init(_ rows: [PublicSearchServiceKey]) { self.rows = rows }
    func set(_ rows: [PublicSearchServiceKey]) { lock.lock(); self.rows = rows; lock.unlock() }
    func keys() throws -> [PublicSearchServiceKey] { lock.lock(); defer { lock.unlock() }; return rows }
}

private func assertReplies(_ outputs: [String], expected: [String]) {
    #expect(outputs.count == expected.count)
    for (output, snapshot) in zip(outputs, expected) {
        var normalized = output.replacingOccurrences(of: "retry-after: [0-9]+", with: "retry-after: <seconds>", options: .regularExpression)
        if normalized.utf8.count > 3000 {
            let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
            normalized = String(normalized.prefix { $0 != "\n" }) + "\n<sha256 \(digest)>"
        }
        #expect(normalized == snapshot)
    }
}

private let featureReplySnapshots: [String] = [
    #"""
    GET /api/avatars/pixel/a.png
    400
    cache-control: private, no-store
    content-length: 36
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Invalid pixel avatar key"}
    """#,
    #"""
    GET /api/avatars/pixel/%21.svg
    400
    cache-control: private, no-store
    content-length: 36
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Invalid pixel avatar key"}
    """#,
    #"""
    GET /api/avatars/pixel/eA.svg
    404
    cache-control: private, no-store
    content-length: 34
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Pixel avatar not found"}
    """#,
    #"""
    GET /api/avatars/pixel/Y2F0.svg
    200
    cache-control: public, max-age=31536000, immutable
    content-length: 2446
    content-type: image/svg+xml; charset=utf-8
    x-robots-tag: noindex, nofollow

    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8" shape-rendering="crispEdges"><rect width="8" height="8" fill="#fbbf24"/><rect x="0" y="0" width="1" height="1" fill="#111827"/><rect x="7" y="0" width="1" height="1" fill="#111827"/><rect x="0" y="1" width="1" height="1" fill="#111827"/><rect x="1" y="1" width="1" height="1" fill="#111827"/><rect x="6" y="1" width="1" height="1" fill="#111827"/><rect x="7" y="1" width="1" height="1" fill="#111827"/><rect x="0" y="2" width="1" height="1" fill="#111827"/><rect x="1" y="2" width="1" height="1" fill="#fbbf24"/><rect x="2" y="2" width="1" height="1" fill="#111827"/><rect x="3" y="2" width="1" height="1" fill="#fbbf24"/><rect x="4" y="2" width="1" height="1" fill="#fbbf24"/><rect x="5" y="2" width="1" height="1" fill="#111827"/><rect x="6" y="2" width="1" height="1" fill="#fbbf24"/><rect x="7" y="2" width="1" height="1" fill="#111827"/><rect x="0" y="3" width="1" height="1" fill="#111827"/><rect x="1" y="3" width="1" height="1" fill="#fbbf24"/><rect x="2" y="3" width="1" height="1" fill="#fbbf24"/><rect x="3" y="3" width="1" height="1" fill="#fbbf24"/><rect x="4" y="3" width="1" height="1" fill="#fbbf24"/><rect x="5" y="3" width="1" height="1" fill="#fbbf24"/><rect x="6" y="3" width="1" height="1" fill="#fbbf24"/><rect x="7" y="3" width="1" height="1" fill="#111827"/><rect x="0" y="4" width="1" height="1" fill="#111827"/><rect x="1" y="4" width="1" height="1" fill="#fbbf24"/><rect x="2" y="4" width="1" height="1" fill="#111827"/><rect x="3" y="4" width="1" height="1" fill="#fbbf24"/><rect x="4" y="4" width="1" height="1" fill="#fbbf24"/><rect x="5" y="4" width="1" height="1" fill="#111827"/><rect x="6" y="4" width="1" height="1" fill="#fbbf24"/><rect x="7" y="4" width="1" height="1" fill="#111827"/><rect x="1" y="5" width="1" height="1" fill="#111827"/><rect x="2" y="5" width="1" height="1" fill="#fbbf24"/><rect x="3" y="5" width="1" height="1" fill="#fbbf24"/><rect x="4" y="5" width="1" height="1" fill="#fbbf24"/><rect x="5" y="5" width="1" height="1" fill="#fbbf24"/><rect x="6" y="5" width="1" height="1" fill="#111827"/><rect x="2" y="6" width="1" height="1" fill="#111827"/><rect x="3" y="6" width="1" height="1" fill="#fbbf24"/><rect x="4" y="6" width="1" height="1" fill="#fbbf24"/><rect x="5" y="6" width="1" height="1" fill="#111827"/><rect x="3" y="7" width="1" height="1" fill="#111827"/><rect x="4" y="7" width="1" height="1" fill="#111827"/></svg>
    """#,
    #"""
    GET /api/servers/abc/public-visibility
    401
    cache-control: private, no-store
    content-length: 74
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Missing or invalid Authorization header","code":"auth_required"}
    """#,
    #"""
    PATCH /api/servers/abc/public-guest-join
    401
    cache-control: private, no-store
    content-length: 74
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Missing or invalid Authorization header","code":"auth_required"}
    """#,
    #"""
    PATCH /api/servers/abc/public-visibility
    401
    cache-control: private, no-store
    content-length: 74
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Missing or invalid Authorization header","code":"auth_required"}
    """#,
    #"""
    PATCH /api/servers/abc/public-search
    401
    cache-control: private, no-store
    content-length: 74
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Missing or invalid Authorization header","code":"auth_required"}
    """#,
    #"""
    GET /api/channels/activity/snapshot
    401
    cache-control: private, no-store
    content-length: 74
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Missing or invalid Authorization header","code":"auth_required"}
    """#,
    #"""
    GET /api/channels/activity/difference
    401
    cache-control: private, no-store
    content-length: 74
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Missing or invalid Authorization header","code":"auth_required"}
    """#,
    #"""
    POST migration-export
    401
    cache-control: private, no-store
    content-length: 74
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Missing or invalid Authorization header","code":"auth_required"}
    """#,
    #"""
    GET /oidc/BAD_SCOPE/.well-known/openid-configuration
    400
    content-length: 32
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"invalid_server_scope"}
    """#,
    #"""
    GET /oidc/nope/.well-known/openid-configuration
    404
    content-length: 21
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Not found"}
    """#,
    #"""
    GET /api/attachments/abc/url?previewToken=x
    401
    cache-control: private, no-store
    content-length: 35
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Authentication required"}
    """#,
    #"""
    GET /api/attachments/abc?previewToken=x
    401
    cache-control: private, no-store
    content-length: 35
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Authentication required"}
    """#,
    #"""
    GET /api/attachments/abc/html-preview-url?previewToken=x
    401
    cache-control: private, no-store
    content-length: 35
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Authentication required"}
    """#,
    #"""
    POST attachments/upload
    401
    cache-control: private, no-store
    content-length: 35
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Authentication required"}
    """#,
    #"""
    POST agent-api/upload
    401
    cache-control: private, no-store
    content-length: 59
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Invalid or expired token","code":"auth_required"}
    """#,
]

private let knowledgeReplySnapshots: [String] = [
    #"""
    noauth
    401
    content-length: 59
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Invalid or expired token","code":"auth_required"}
    """#,
    #"""
    readonly
    403
    content-length: 134
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"code":"capability_not_authorized","error":"Agent credential is not authorized for this capability","requiredCapability":"knowledge"}
    """#,
    #"""
    nosource
    400
    content-length: 112
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"code":"knowledge_source_invalid","error":"Knowledge requests must come from an implemented source","ok":false}
    """#,
    #"""
    notopic
    400
    content-length: 89
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"code":"knowledge_topic_invalid","error":"topic query parameter is required","ok":false}
    """#,
    #"""
    noIntent
    400
    content-length: 75
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"code":"knowledge_intent_invalid","error":"intent is required","ok":false}
    """#,
    #"""
    badReason
    400
    content-length: 94
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"code":"knowledge_reason_invalid","error":"reason must be at least 12 characters","ok":false}
    """#,
    #"""
    turnMismatch
    <5551 bytes sha256 45aa129c87b056c5f22e834b7145ce6e7b037c60e61e5c08ab14489ff6f14f59>
    200
    content-length: 5447
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"content":"---\ndoc_id: slock-home\ntitle: SLOCK_HOME user-data root\ndescription: The app-level local data root shared by the daemon, the bundled agent CLI and runtime helpers; what lives under it, how to relocate it, and how to run several environments side by side.\naliases:\n  - slock-home\
    """#,
    #"""
    get ok
    <5551 bytes sha256 45aa129c87b056c5f22e834b7145ce6e7b037c60e61e5c08ab14489ff6f14f59>
    200
    content-length: 5447
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"content":"---\ndoc_id: slock-home\ntitle: SLOCK_HOME user-data root\ndescription: The app-level local data root shared by the daemon, the bundled agent CLI and runtime helpers; what lives under it, how to relocate it, and how to run several environments side by side.\naliases:\n  - slock-home\
    """#,
    #"""
    get legacy
    <5551 bytes sha256 45aa129c87b056c5f22e834b7145ce6e7b037c60e61e5c08ab14489ff6f14f59>
    200
    content-length: 5447
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"content":"---\ndoc_id: slock-home\ntitle: SLOCK_HOME user-data root\ndescription: The app-level local data root shared by the daemon, the bundled agent CLI and runtime helpers; what lives under it, how to relocate it, and how to run several environments side by side.\naliases:\n  - slock-home\
    """#,
    #"""
    get missing
    <1880 bytes sha256 f605aecc2173b17dd4606b97236fde21d27bedad022ffeea911f22b550dbb0d6>
    404
    content-length: 1776
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"candidates":[{"matchedTerms":["here","noth"],"slug":"account","title":"Account"},{"matchedTerms":["here","noth"],"slug":"action-cards","title":"Action Cards"},{"matchedTerms":["here","noth"],"slug":"agent","title":"Agent"}],"code":"knowledge_not_found","error":"Manual topic not found. Closest\#u{20}
    """#,
    #"""
    get missing legacy
    <1426 bytes sha256 ceadfd45c98360d6af77dd55d02c7a27ab727f4a4c4cfc52b40f3c400695aa4a>
    404
    content-length: 1322
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"candidates":[{"matchedTerms":["here","noth"],"slug":"account","title":"Account"},{"matchedTerms":["here","noth"],"slug":"action-cards","title":"Action Cards"},{"matchedTerms":["here","noth"],"slug":"agent","title":"Agent"}],"code":"knowledge_not_found","error":"Manual topic not found. Closest\#u{20}
    """#,
    #"""
    search noquery
    400
    content-length: 83
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"code":"knowledge_query_invalid","error":"query parameter is required","ok":false}
    """#,
    #"""
    search badscope
    400
    content-length: 95
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"code":"knowledge_scope_invalid","error":"scope must be omitted or set to recipes","ok":false}
    """#,
    #"""
    search ok
    <2652 bytes sha256 58266e25492af95a31ad7fe33d2e7a27253a1977daceb4072fa345501b9e3965>
    200
    content-length: 2548
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"ok":true,"query":"tasks","scope":null,"results":[{"slug":"task","title":"Task","firstScreen":"# Task\nA task is a claimable work item. The ordinary path is `todo` → `in_progress` → `in_review` → `done`, and a fifth status, `closed`, records work that will not be done. Tasks are built on top of
    """#,
    #"""
    search recipes
    <2823 bytes sha256 42fa05e9aafa38964cf75309cce150208637f6531f98bb52bd0cb01778e62c19>
    200
    content-length: 2719
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"ok":true,"query":"tasks","scope":"recipes","results":[{"slug":"recipes/technique/task-claim-lock","title":"Before doing work, claim the task — the claim is the concurrency lock","firstScreen":"# Before doing work, claim the task — the claim is the concurrency lock\n### When\nUse this whenever\#u{20}
    """#,
    #"""
    search miss
    404
    content-length: 399
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"code":"knowledge_not_found","error":"Manual search found no matching topics. Retry with different keywords, keeping your --intent\/--reason.","ok":false,"suggested_next_action":"Retry with different keywords, keeping your --intent\/--reason. To browse all topics, run:\nraft manual get index --intent \"Learn available Raft workflows\" --reason \"Browse the topic catalog after a missing topic\""}
    """#,
    #"""
    search miss scope
    404
    content-length: 240
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"code":"knowledge_not_found","error":"Manual search found no matching topics in recipes. Retry with different keywords.","ok":false,"suggested_next_action":"Retry with different keywords. To browse all topics, run:\nraft manual get index"}
    """#,
    #"""
    search lang
    404
    content-length: 398
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"code":"knowledge_language_unsupported","error":"The Manual is written in English and is not translated. Search in English.","ok":false,"suggested_next_action":"Retry the same question using English keywords, keeping your --intent\/--reason. To browse all topics, run:\nraft manual get index --intent \"Learn available Raft workflows\" --reason \"Browse the topic catalog after a missing topic\""}
    """#,
]

private let middlewareReplySnapshots: [String] = [
    #"""
    GET gate agent-api
    503
    cache-control: private, no-store
    content-length: 111
    content-type: application/json
    sec-slock-api-version: 1

    {"code":"experimental_surface_disabled","error":"Experimental internal surface is disabled","retry_after":null}
    """#,
    #"""
    POST gate computer
    503
    cache-control: private, no-store
    content-length: 111
    content-type: application/json
    sec-slock-api-version: 1

    {"code":"experimental_surface_disabled","error":"Experimental internal surface is disabled","retry_after":null}
    """#,
    #"""
    GET boom
    500
    content-length: 119
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow
    x-slock-error-id: <uuid>

    {"error":"Internal server error","code":"internal_server_error","correlationId":"<uuid>"}
    """#,
    #"""
    scope unauth
    401
    content-length: 47
    content-type: application/json

    {"error":"Unauthorized","code":"auth_required"}
    """#,
    #"""
    scope machine
    413
    content-length: 110
    content-type: application/json

    {"error":"Scope attestation body is too large","code":"scope_attestation_body_too_large","limitBytes":1048576}
    """#,
    #"""
    control unauth
    401
    content-length: 47
    content-type: application/json

    {"error":"Unauthorized","code":"auth_required"}
    """#,
    #"""
    control computer
    413
    content-length: 109
    content-type: application/json

    {"error":"Migration control body is too large","code":"migration_control_body_too_large","limitBytes":589824}
    """#,
    #"""
    global
    413
    content-length: 69
    content-type: application/json

    {"error":"Request body is too large","code":"request_body_too_large"}
    """#,
    #"""
    search bad key
    401
    cache-control: no-store
    content-length: 84
    content-type: application/json

    {"code":"service_credential_invalid","error":"Public search service access refused"}
    """#,
    #"""
    search ok
    200
    cache-control: no-store
    content-length: 220
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nof
    """#,
    #"""
    search limited
    429
    cache-control: no-store
    content-length: 83
    content-type: application/json
    retry-after: <seconds>

    {"code":"service_rate_limited","error":"Public search service rate limit exceeded"}
    """#,
    #"""
    search unavailable
    503
    cache-control: no-store
    content-length: 77
    content-type: application/json

    {"code":"service_unavailable","error":"Public search service access refused"}
    """#,
    #"""
    search method
    405
    allow: GET, HEAD
    cache-control: no-store
    content-length: 30
    content-type: application/json; charset=utf-8
    x-robots-tag: noindex, nofollow

    {"error":"Method not allowed"}
    """#,
]
