import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private let identityTermsVersion = "2026-05-12"

private func identityRegister(_ client: any Client, email: String) async throws -> (body: [String: Any], token: String, userId: String) {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/register") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\",\"acceptTerms\":true,\"termsVersion\":\"\(identityTermsVersion)\",\"privacyVersion\":\"\(identityTermsVersion)\"}")
    }
    #expect(response.status == .ok)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    let user = body["user"] as? [String: Any] ?? [:]
    return (body, body["accessToken"] as? String ?? "", user["id"] as? String ?? "")
}

private func identityRequest(
    _ client: any Client, _ method: HTTPRequest.Method, path: String, token: String, body: String
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    return try await client.send(method, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func identityPost(_ client: any Client, path: String, token: String, body: String) async throws -> ClientResponse {
    try await identityRequest(client, .post, path: path, token: token, body: body)
}

@Test func identitySetupCreatesPendingAccountAndCompletesWithCAS() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let registered = try await identityRegister(client, email: "identity-pending-flow@slock.test")
            let pendingName = registered.body["user"] as? [String: Any]
            let name = pendingName?["name"] as? String ?? ""
            #expect(name.range(of: "^pending_[0-9a-f]{20}$", options: .regularExpression) != nil)
            // The pending handle is an internal reservation. It is never copied
            // into the person-facing display name: upstream inserts
            // `displayName: null` for a deferred account and the public body
            // publishes that null, so the Web's identity form starts empty and
            // mirrors the handle the person chooses.
            #expect(pendingName?["displayName"] is NSNull)
            #expect(pendingName?["profileSetupCompletedAt"] is NSNull)
            #expect(pendingName?["profileSetupSuggestedHandle"] as? String == "identity-pending-flow")
            #expect(pendingName?["profileSetupProvider"] is NSNull)

            var meHeaders = HTTPFields()
            meHeaders[.authorization] = "Bearer \(registered.token)"
            let me = try await client.get("/api/auth/me", headers: meHeaders)
            #expect(me.status == .ok)
            let meBody = (try? JSONSerialization.jsonObject(with: Data((me.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(meBody["profileSetupProvider"] is NSNull)
            #expect(meBody["displayName"] is NSNull)
            #expect(meBody["profileSetupCompletedAt"] is NSNull)

            accounts.markEmailVerified(userId: registered.userId)
            let blocked = try await identityPost(
                client,
                path: "/api/servers",
                token: registered.token,
                body: "{\"name\":\"Blocked Server\",\"slug\":\"blocked-server\"}"
            )
            #expect(blocked.status == .forbidden)
            let blockedBody = (try? JSONSerialization.jsonObject(with: Data((blocked.body.string ?? "").utf8))) as? [String: Any]
            #expect(blockedBody?["code"] as? String == "PROFILE_SETUP_REQUIRED")
            #expect(blockedBody?["error"] as? String == "Profile setup required")

            for reserved in ["pending_not_allowed", "Reminders"] {
                let response = try await identityPost(
                    client,
                    path: "/api/auth/me/complete-profile",
                    token: registered.token,
                    body: "{\"name\":\"\(reserved)\",\"displayName\":\"Pending User\"}"
                )
                #expect(response.status == .badRequest)
                let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
                #expect(body?["code"] as? String == "PROFILE_SETUP_NAME_RESERVED")
            }

            let complete = try await identityPost(
                client,
                path: "/api/auth/me/complete-profile",
                token: registered.token,
                body: "{\"name\":\"final-handle\",\"displayName\":\"Final User\"}"
            )
            #expect(complete.status == .ok)
            let completed = (try? JSONSerialization.jsonObject(with: Data((complete.body.string ?? "").utf8))) as? [String: Any]
            #expect(completed?["name"] as? String == "final-handle")
            #expect(completed?["displayName"] as? String == "Final User")
            // Upstream clears the editable handle suggestion when it writes the
            // final identity, so the completed public body carries null.
            #expect(completed?["profileSetupSuggestedHandle"] is NSNull)
            #expect(completed?["profileSetupCompletedAt"] is String)
            // The pinned auth store replaces its whole user with this flat body.
            #expect(completed?["id"] as? String == registered.userId)
            #expect(completed?["emailVerified"] as? Bool == true)
            #expect(completed?["user"] == nil)

            let replay = try await identityPost(
                client,
                path: "/api/auth/me/complete-profile",
                token: registered.token,
                body: "{\"name\":\"final-handle\",\"displayName\":\"Final User\"}"
            )
            #expect(replay.status == .ok)
            let replayed = try #require(try JSONSerialization.jsonObject(with: Data((replay.body.string ?? "").utf8)) as? [String: Any])
            #expect(replayed["id"] as? String == registered.userId)
            #expect(replayed["emailVerified"] as? Bool == true)
            #expect(replayed["profileSetupCompletedAt"] as? String == completed?["profileSetupCompletedAt"] as? String)
            #expect(replayed["user"] == nil)

            let changed = try await identityPost(
                client,
                path: "/api/auth/me/complete-profile",
                token: registered.token,
                body: "{\"name\":\"final-handle\",\"displayName\":\"Changed User\"}"
            )
            #expect(changed.status == .conflict)
            let changedBody = (try? JSONSerialization.jsonObject(with: Data((changed.body.string ?? "").utf8))) as? [String: Any]
            #expect(changedBody?["code"] as? String == "PROFILE_SETUP_ALREADY_COMPLETED")

            let completedMe = try await client.get("/api/auth/me", headers: meHeaders)
            #expect(completedMe.status == .ok)
            let completedMeBody = (try? JSONSerialization.jsonObject(with: Data((completedMe.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(completedMeBody["name"] as? String == "final-handle")
            #expect(completedMeBody["displayName"] as? String == "Final User")
            #expect(completedMeBody["profileSetupSuggestedHandle"] is NSNull)

            let allowed = try await identityPost(
                client,
                path: "/api/servers",
                token: registered.token,
                body: "{\"name\":\"Allowed Server\",\"slug\":\"allowed-server\"}"
            )
            #expect(allowed.status == .ok)

            let concurrent = try await identityRegister(client, email: "identity-concurrent-cas@slock.test")
            accounts.markEmailVerified(userId: concurrent.userId)
            let concurrentToken = concurrent.token
            async let first = identityPost(
                client,
                path: "/api/auth/me/complete-profile",
                token: concurrentToken,
                body: "{\"name\":\"concurrent-handle\",\"displayName\":\"Concurrent A\"}"
            )
            async let second = identityPost(
                client,
                path: "/api/auth/me/complete-profile",
                token: concurrentToken,
                body: "{\"name\":\"concurrent-handle\",\"displayName\":\"Concurrent B\"}"
            )
            let responses = try await [first, second]
            let statuses = responses.map(\.status.code).sorted()
            #expect(statuses == [200, 409])
            let loser = responses.first { $0.status == .conflict }
            let loserBody = (try? JSONSerialization.jsonObject(with: Data((loser?.body.string ?? "").utf8))) as? [String: Any]
            #expect(loserBody?["code"] as? String == "PROFILE_SETUP_ALREADY_COMPLETED")
        }
    }
}

@Test func completedProfileKeepsANullSuggestionAndPatchMeRepairsTheDisplayName() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let registered = try await identityRegister(client, email: "identity-display-repair@slock.test")
            accounts.markEmailVerified(userId: registered.userId)

            // The production shape: a completed identity whose display name is a
            // pending handle. Upstream accepts it here — only the handle is
            // checked for the `pending_` prefix — and the completion write is
            // one-shot, so PATCH is the published repair path.
            let complete = try await identityPost(
                client,
                path: "/api/auth/me/complete-profile",
                token: registered.token,
                body: "{\"name\":\"chosen-handle\",\"displayName\":\"pending_0123456789abcdef0123\"}"
            )
            #expect(complete.status == .ok)
            let completed = try #require(try JSONSerialization.jsonObject(with: Data((complete.body.string ?? "").utf8)) as? [String: Any])
            #expect(completed["name"] as? String == "chosen-handle")
            #expect(completed["displayName"] as? String == "pending_0123456789abcdef0123")
            #expect(completed["profileSetupSuggestedHandle"] is NSNull)

            let patched = try await identityRequest(
                client, .patch, path: "/api/auth/me", token: registered.token,
                body: "{\"displayName\":\"Kevin Chou\"}"
            )
            #expect(patched.status == .ok)
            let patchedBody = try #require(try JSONSerialization.jsonObject(with: Data((patched.body.string ?? "").utf8)) as? [String: Any])
            #expect(patchedBody["displayName"] as? String == "Kevin Chou")
            #expect(patchedBody["name"] as? String == "chosen-handle")

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(registered.token)"
            let me = try await client.get("/api/auth/me", headers: headers)
            let meBody = try #require(try JSONSerialization.jsonObject(with: Data((me.body.string ?? "").utf8)) as? [String: Any])
            #expect(meBody["displayName"] as? String == "Kevin Chou")

            // The exact-payload replay still answers 200 after the repair.
            let replay = try await identityPost(
                client,
                path: "/api/auth/me/complete-profile",
                token: registered.token,
                body: "{\"name\":\"chosen-handle\",\"displayName\":\"Kevin Chou\"}"
            )
            #expect(replay.status == .ok)

            // A present null clears the display name. The replay comparison is
            // against the stored value, never the handle standing in for null:
            // upstream answers 409 for this payload on a completed account.
            let cleared = try await identityRequest(
                client, .patch, path: "/api/auth/me", token: registered.token,
                body: "{\"displayName\":null}"
            )
            #expect(cleared.status == .ok)
            let clearedBody = try #require(try JSONSerialization.jsonObject(with: Data((cleared.body.string ?? "").utf8)) as? [String: Any])
            #expect(clearedBody["displayName"] is NSNull)
            let derivedReplay = try await identityPost(
                client,
                path: "/api/auth/me/complete-profile",
                token: registered.token,
                body: "{\"name\":\"chosen-handle\",\"displayName\":\"chosen-handle\"}"
            )
            #expect(derivedReplay.status == .conflict)
            let derivedReplayBody = (try? JSONSerialization.jsonObject(with: Data((derivedReplay.body.string ?? "").utf8))) as? [String: Any]
            #expect(derivedReplayBody?["code"] as? String == "PROFILE_SETUP_ALREADY_COMPLETED")

            // An absent key leaves the stored null alone; the public body prints
            // null instead of deriving the handle.
            let untouched = try await identityRequest(
                client, .patch, path: "/api/auth/me", token: registered.token,
                body: "{\"shareUsageData\":true}"
            )
            let untouchedBody = try #require(try JSONSerialization.jsonObject(with: Data((untouched.body.string ?? "").utf8)) as? [String: Any])
            #expect(untouchedBody["displayName"] is NSNull)
        }
    }
}

@Test func identityAdmissionUsesHandleRatherThanCompletionTimestamp() async throws {
    let stamp = Date(timeIntervalSince1970: 1_800_000_000)
    let cases: [(name: String, completedAt: Date?, allowed: Bool)] = [
        ("", nil, false), ("", stamp, false),
        ("pending_legacy", nil, false), ("pending_legacy", stamp, false),
        ("PeNdInG_mixed", nil, false), ("PeNdInG_mixed", stamp, false),
        ("legacy-handle", nil, true), ("legacy-handle", stamp, true),
    ]
    let services = FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {})
    try await withApp { app in
        configure(app, services: services)
        try await app.testing { client in
            for (index, item) in cases.enumerated() {
                let email = "identity-admission-\(index)@example.com"
                let registered = try await identityRegister(client, email: email)
                // Seed legacy row disagreements; no password material or global fixture default changes.
                services.emailAccounts.authProfileStore.state.withLock { state in
                    state.accountSurface.accounts[email]?.emailVerified = true
                    state.accountSurface.accounts[email]?.name = item.name
                    state.accountSurface.accounts[email]?.profileSetupCompletedAt = item.completedAt
                }
                let slug = "identity-admission-\(index)"
                let response = try await identityPost(client, path: "/api/servers", token: registered.token,
                    body: "{\"name\":\"Identity Matrix\",\"slug\":\"\(slug)\"}")
                #expect(response.status == (item.allowed ? .ok : .forbidden))
                if !item.allowed {
                    #expect(response.body.string == "{\"error\":\"Profile setup required\",\"code\":\"PROFILE_SETUP_REQUIRED\"}")
                    #expect(services.emailAccounts.oauth.serverIdForSlug(slug) == nil)
                } else {
                    #expect(services.emailAccounts.oauth.serverIdForSlug(slug) != nil)
                }
            }
        }
    }
}
