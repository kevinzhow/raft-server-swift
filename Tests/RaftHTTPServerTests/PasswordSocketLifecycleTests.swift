import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct PasswordSocketAuth: RealtimeAuthorizing {
    let core: AuthCoreService
    let membership: SocketMembershipService
    func userId(forAccessToken token: String) -> String? { core.sessionIdentity(accessToken: token)?.userId }
    func sessionFamilyId(forAccessToken token: String) -> String? { core.sessionIdentity(accessToken: token)?.familyId }
    func serverRole(serverId: String, userId: String) -> String? { membership.serverRole(serverId: serverId, userId: userId) }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }
}

private func passwordSocketRequest(_ client: any Client, _ method: HTTPRequest.Method, _ path: String,
                                   body: [String: String], token: String? = nil) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let token { headers[.authorization] = "Bearer \(token)" }
    let bytes = try JSONSerialization.data(withJSONObject: body)
    return try await client.send(method, headers: headers, to: URI(string: path)) { $0.body = .init(data: bytes) }
}

private func passwordConnect(_ socket: SocketIOTestClient, token: String, serverId: String) async throws {
    _ = try #require(await socket.waitForText { $0.hasPrefix("0") })
    let frame = try JSONSerialization.data(withJSONObject: ["token": token, "serverId": serverId])
    socket.send("40" + String(decoding: frame, as: UTF8.self))
    _ = try #require(await socket.waitForText { $0 == "42[\"rooms:joined\"]" })
}

private func passwordSocketLifecycle(reset: Bool) async throws {
    let accounts = EmailLoginDirectory()
    let userId = "synthetic-password-socket-user"
    let serverId = "synthetic-password-socket-server"
    let email = "socket-password@example.com"
    let legacyToken = "synthetic-legacy-familyless-access"
    accounts.addAccount(id: userId, email: email, password: "before-password")
    accounts.oauth.addOwnedServer(id: serverId, slug: "password-socket", name: "Password Socket", ownerId: userId)
    // A known legacy persistence fixture: access exists without any family or
    // refresh metadata. The handshake uses the real AuthCoreService lookup.
    accounts.authProfileStore.state.withLock { $0.accountSurface.accessTokens[legacyToken] = userId }
    if reset {
        accounts.authProfileStore.setResetToken(hash: AuthTokenCodec.sha256("synthetic-socket-reset"), userId: userId,
                                               expiresAt: Date().addingTimeInterval(60))
    }
    let realtime = try await RealtimeServer.start(auth: PasswordSocketAuth(core: accounts.authCore, membership: accounts.socketMembership))
    do {
        let legacy = try await SocketIOTestClient(port: realtime.port)
        defer { legacy.close() }
        try await passwordConnect(legacy, token: legacyToken, serverId: serverId)
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                                                     pingDatabase: {}, emailAccounts: accounts, realtime: realtime.hub))
            try await app.testing { client in
                let changed: ClientResponse
                if reset {
                    changed = try await passwordSocketRequest(client, .post, "/api/auth/reset-password",
                        body: ["token": "synthetic-socket-reset", "password": "after-password"])
                } else {
                    changed = try await passwordSocketRequest(client, .patch, "/api/auth/me",
                        body: ["currentPassword": "before-password", "newPassword": "after-password"], token: legacyToken)
                }
                #expect(changed.status == .ok)
                #expect(await legacy.waitForClose())
                let loggedIn = try await passwordSocketRequest(client, .post, "/api/auth/login",
                    body: ["email": email, "password": "after-password"])
                #expect(loggedIn.status == .ok)
                let object = try #require(JSONSerialization.jsonObject(with: Data((loggedIn.body.string ?? "").utf8)) as? [String: Any])
                let token = try #require(object["accessToken"] as? String)
                let fresh = try await SocketIOTestClient(port: realtime.port)
                defer { fresh.close() }
                try await passwordConnect(fresh, token: token, serverId: serverId)
                // Replaying the old empty-family revocation must not close a
                // newly authenticated proper family. Observe real wire delivery.
                realtime.hub.revokeFamilies(userId: userId, familyIds: [])
                let nonce = UUID().uuidString.lowercased()
                let payload = "{\"nonce\":\"\(nonce)\"}"
                let expected = "42[\"password:live-family\",\(payload)]"
                realtime.hub.emit(room: "user:\(userId)", event: "password:live-family", payloadJSON: payload)
                _ = try #require(await fresh.waitForText { $0 == expected })
            }
        }
    } catch {
        try? await realtime.close()
        throw error
    }
    try await realtime.close()
}

@Test func passwordResetClosesLegacyFamilylessSocketAndPreservesNewFamily() async throws {
    try await passwordSocketLifecycle(reset: true)
}

@Test func passwordChangeClosesLegacyFamilylessSocketAndPreservesNewFamily() async throws {
    try await passwordSocketLifecycle(reset: false)
}
