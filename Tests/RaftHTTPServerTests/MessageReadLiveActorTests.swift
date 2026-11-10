import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private func liveReadObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
}

@Test func protectedReadsRejectMissingAndRetiredAccountsBeforeResourceValidation() async throws {
    for removal in [false, true] {
        let accounts = EmailLoginDirectory()
        accounts.configureAuthCoreForTesting { $0.releaseBranch = "staging" }
        let capability = "live-read-retirement-capability-1234567890"
        let email = removal ? "live-missing@mail.build" : "live-retired@mail.build"
        let control = UUID().uuidString.lowercased()
        accounts.addAccount(id: control, email: "live-control@example.test", password: "password123")
        accounts.markEmailVerified(userId: control)
        let controlToken = accounts.mintAccessTokenForTesting(userId: control)
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
            try await app.testing { client in
                func post(_ path: String, body: String, authorization: String? = nil) async throws -> ClientResponse {
                    var fields = HTTPFields(); fields[.contentType] = "application/json"
                    fields[.authorization] = authorization
                    return try await client.send(.post, headers: fields, to: URI(string: path)) { request in request.body = .init(string: body) }
                }
                let registration = try await post("/api/auth/register", body: "{\"email\":\"\(email)\",\"password\":\"password123\",\"name\":\"live-reader\",\"acceptTerms\":true,\"termsVersion\":\"\(AuthLegalPolicy.termsVersion)\",\"privacyVersion\":\"\(AuthLegalPolicy.privacyVersion)\",\"stagingSelfAccountCapability\":\"\(capability)\"}")
                #expect(registration.status == .ok)
                let registered = try liveReadObject(registration)
                let user = try #require(registered["user"] as? [String: Any])
                let owner = try #require(user["id"] as? String)
                accounts.markEmailVerified(userId: owner)
                let login = try await post("/api/auth/login", body: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                #expect(login.status == .ok)
                let sessionToken = try #require(try liveReadObject(login)["accessToken"] as? String)
                let handle = removal ? "live_missing_reader" : "live_retired_reader"
                let profile = try await post("/api/auth/me/complete-profile", body: "{\"name\":\"\(handle)\",\"displayName\":\"Live Reader\"}", authorization: "Bearer \(sessionToken)")
                #expect(profile.status == .ok)
                let completed = try #require(accounts.authProfileStore.account(userId: owner))
                #expect(completed.name == handle)
                #expect(!completed.name.lowercased().hasPrefix("pending_"))
                // A real retained legacy credential has no session-family row.
                // Keep it through retirement to test Node's live-account gate.
                let legacy = "legacy-live-reader-\(UUID().uuidString.lowercased())"
                accounts.authProfileStore.accessTokens[legacy] = owner
                #expect(accounts.authProfileStore.accessTokenFamilies[legacy] == nil)
                let server = UUID().uuidString.lowercased()
                accounts.oauth.addOwnedServer(id: server, slug: "live-read-scope", name: "Live read scope", ownerId: owner)
                accounts.oauth.addMember(serverId: server, userId: control, role: "member")
                let channel = accounts.oauth.createChannel(serverId: server, name: "live-read-public", creatorUserId: owner)
                accounts.addPostableChannel(serverId: server, channelId: channel, memberId: owner, name: "live-read-public")
                let message = accounts.addHumanMessageForTesting(channelId: channel, senderId: owner, content: "live-profile-read-secret")
                func headers(_ token: String, scope: Bool = true) -> HTTPFields {
                    var fields = HTTPFields(); fields[.authorization] = "Bearer \(token)"
                    if scope { fields[HTTPField.Name("X-Server-Id")!] = server }
                    return fields
                }
                let paths = ["/api/messages/channel/\(channel)", "/api/messages/sync?channel_id=\(channel)",
                    "/api/messages/context/\(message)?channelId=\(channel)", "/api/messages/search?q=live-profile",
                    "/api/messages/sync?since_seq=0", "/api/tasks/channel/\(channel)"]
                for path in paths {
                    let active = try await client.get(URI(string: path), headers: headers(legacy))
                    #expect(active.status == .ok)
                }
                if removal {
                    let key = try #require(accounts.authProfileStore.accounts.first { $0.value.id == owner }?.key)
                    let deletedAccount = accounts.authProfileStore.accounts.removeValue(forKey: key)
                    let deleted = try #require(deletedAccount)
                    #expect(deleted.id == owner)
                } else {
                    let retired = try await post("/api/auth/staging-self-account/retire", body: "{\"userId\":\"\(owner)\",\"capability\":\"\(capability)\"}", authorization: "Bearer \(sessionToken)")
                    #expect(retired.status == .ok)
                    #expect(accounts.authProfileStore.account(userId: owner)?.retiredAt != nil)
                }
                #expect(accounts.authProfileStore.accessTokens[legacy] == owner)
                #expect(accounts.authProfileStore.accessTokenFamilies[legacy] == nil)
                let invalidPaths = ["/api/messages/context/not-an-id", "/api/messages/search?sort=sideways",
                    "/api/messages/sync?since_seq=invalid", "/api/tasks/channel/not-a-uuid"]
                for path in paths + invalidPaths {
                    let denied = try await client.get(URI(string: path), headers: headers(legacy))
                    #expect(denied.status == .unauthorized)
                    #expect(denied.body.string == #"{"error":"Invalid or expired token","code":"auth_required"}"#)
                    #expect(!(denied.body.string ?? "").contains("live-profile-read-secret"))
                }
                let missingScope = try await client.get("/api/messages/search?q=live-profile", headers: headers(legacy, scope: false))
                #expect(missingScope.status == .unauthorized)
                let stillActive = try await client.get(URI(string: "/api/tasks/channel/\(channel)"), headers: headers(controlToken))
                #expect(stillActive.status == .ok)
            }
        }
    }
}
