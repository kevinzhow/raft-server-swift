import Foundation
import RaftRealtime
import Testing
import TestSupport
@testable import RaftHTTP
@testable import RaftServer

// Actual executable adapter and retained owners; no authorization stub or spy.
func activeRealtimeConnect(port: Int, token: String, serverId: String? = nil) async throws -> ProtocolPGSocket {
    let socket = try await ProtocolPGSocket.connect(port: port, path: "/socket.io/?EIO=4&transport=websocket")
    do {
        _ = try await socket.nextText { $0.hasPrefix("0") }
        var body: [String: String] = ["token": token, "clientKind": "web"]
        if let serverId { body["serverId"] = serverId }
        let bytes = try JSONSerialization.data(withJSONObject: body)
        try await socket.send("40" + String(decoding: bytes, as: UTF8.self))
        let response = try await socket.nextText { $0.hasPrefix("40") || $0.hasPrefix("44") }
        try #require(response.hasPrefix("40"), "Expected authenticated Socket.IO connection")
        if serverId != nil { _ = try await socket.nextText { $0 == "42[\"rooms:joined\"]" } }
        return socket
    } catch { await socket.close(); throw error }
}

func activeRealtimeClosed(_ socket: ProtocolPGSocket) async throws {
    do {
        _ = try await socket.nextText(since: socket.count) { _ in false }
        Issue.record("Expected the existing network connection to close")
    } catch ProtocolPGFailure.closed {
        // A real channelInactive/close frame, not a timeout or missing event.
    }
}

func activeRealtimeRefused(port: Int, token: String, serverId: String? = nil) async throws {
    let socket = try await ProtocolPGSocket.connect(port: port, path: "/socket.io/?EIO=4&transport=websocket")
    do {
        _ = try await socket.nextText { $0.hasPrefix("0") }
        var body: [String: String] = ["token": token, "clientKind": "web"]
        if let serverId { body["serverId"] = serverId }
        try await socket.send("40" + String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        let response = try await socket.nextText { $0.hasPrefix("40") || $0.hasPrefix("44") }
        try #require(response == "44{\"message\":\"Invalid or expired token\"}")
        try await activeRealtimeClosed(socket)
        #expect(!socket.texts.contains { $0.hasPrefix("40") || $0 == "42[\"rooms:joined\"]" })
    } catch { await socket.close(); throw error }
    await socket.close()
}

// Used only for bounded overlap with an actual published logout. A connection
// may legitimately be admitted before commit or refused after it; both must
// be closed once the committed logout and all handshake attempts finish.
func activeRealtimeAttempt(port: Int, token: String, serverId: String) async throws -> ProtocolPGSocket {
    let socket = try await ProtocolPGSocket.connect(port: port, path: "/socket.io/?EIO=4&transport=websocket")
    do {
        _ = try await socket.nextText { $0.hasPrefix("0") }
        let body = try JSONSerialization.data(withJSONObject: ["token": token, "serverId": serverId])
        try await socket.send("40" + String(decoding: body, as: UTF8.self))
        do {
            let reply = try await socket.nextText { $0.hasPrefix("40") || $0.hasPrefix("44") }
            #expect(reply.hasPrefix("40") || reply == "44{\"message\":\"Invalid or expired token\"}")
        } catch ProtocolPGFailure.closed {
            // A pending handshake revoked between identity and admission.
        }
        return socket
    } catch { await socket.close(); throw error }
}

@Suite(.serialized) struct RealtimeActiveAuthTests {
    @Test(arguments: ["revoked-set", "revoked-row", "missing-family", "foreign-family", "missing-account", "retired-account"])
    func inactiveStoredPrincipalCannotHandshake(_ reason: String) async throws {
        let accounts = EmailLoginDirectory()
        let user = UUID().uuidString.lowercased()
        let email = "active-realtime-\(user)@slock.test"
        accounts.addAccount(id: user, email: email, password: "realtime-password123")
        let tokens = accounts.authProfileStore.openSession(userId: user)
        let family = try #require(accounts.authProfileStore.pushPrincipal(accessToken: tokens.accessToken)?.familyId)
        // These are concrete restored-state fixtures, not fake authorization
        // answers. Every handshake uses the real ledger adapter over these rows.
        accounts.authProfileStore.state.withLock { state in
            switch reason {
            case "revoked-set": state.accountSurface.revokedFamilies.insert(family)
            case "revoked-row": state.accountSurface.sessionFamilies[family]?.revokedAt = Date()
            case "missing-family": state.accountSurface.sessionFamilies.removeValue(forKey: family)
            case "foreign-family": state.accountSurface.sessionFamilies[family] = SessionFamily(userId: UUID().uuidString.lowercased())
            case "missing-account": state.accountSurface.accounts.removeValue(forKey: email)
            case "retired-account": state.accountSurface.accounts[email]?.retiredAt = Date()
            default: break
            }
        }
        let realtime = try await RealtimeServer.start(auth: LedgerRealtimeAuth(authCore: accounts.authCore, membership: accounts.socketMembership))
        do { try await activeRealtimeRefused(port: realtime.port, token: tokens.accessToken) }
        catch { try? await realtime.close(); throw error }
        try await realtime.close()
        // Push's intentionally weaker lookup remains independent of realtime.
        #expect(accounts.authProfileStore.pushPrincipal(accessToken: tokens.accessToken)?.userId == user)
    }

    @Test(arguments: [false, true])
    func activeUnverifiedAndLegacyFamilylessPrincipalsStillConnect(_ legacy: Bool) async throws {
        let accounts = EmailLoginDirectory()
        let user = UUID().uuidString.lowercased()
        accounts.addAccount(id: user, email: "live-realtime-\(user)@slock.test", password: "realtime-password123")
        let token: String
        if legacy {
            token = "synthetic-realtime-legacy-\(UUID().uuidString.lowercased())"
            accounts.authProfileStore.state.withLock { $0.accountSurface.accessTokens[token] = user }
        } else { token = accounts.authProfileStore.openSession(userId: user).accessToken }
        let realtime = try await RealtimeServer.start(auth: LedgerRealtimeAuth(authCore: accounts.authCore, membership: accounts.socketMembership))
        do {
            let socket = try await activeRealtimeConnect(port: realtime.port, token: token)
            do {
                let payload = "{\"nonce\":\"\(UUID().uuidString.lowercased())\"}"
                realtime.hub.emit(room: "user:\(user)", event: "test:active-principal", payloadJSON: payload)
                _ = try await socket.nextText { $0 == "42[\"test:active-principal\",\(payload)]" }
            } catch { await socket.close(); throw error }
            await socket.close()
        } catch { try? await realtime.close(); throw error }
        try await realtime.close()
    }

    @Test(arguments: ["foreign", "revoked-set", "revoked-row"])
    func refreshDoesNotReactivateAnInvalidExistingFamily(_ reason: String) throws {
        let accounts = EmailLoginDirectory()
        let user = UUID().uuidString.lowercased()
        accounts.addAccount(id: user, email: "invalid-refresh-\(user)@slock.test", password: "realtime-password123")
        let tokens = accounts.authProfileStore.openSession(userId: user)
        let family = try #require(accounts.authProfileStore.pushPrincipal(accessToken: tokens.accessToken)?.familyId)
        accounts.authProfileStore.state.withLock {
            if reason == "foreign" { $0.accountSurface.sessionFamilies[family]?.userId = "foreign-owner" }
            if reason == "revoked-set" { $0.accountSurface.revokedFamilies.insert(family) }
            if reason == "revoked-row" { $0.accountSurface.sessionFamilies[family]?.revokedAt = Date() }
        }
        let request = try JSONDecoder().decode(RefreshTokenRequest.self,
            from: JSONSerialization.data(withJSONObject: ["refreshToken": tokens.refreshToken]))
        #expect(throws: AuthCoreError.invalidRefreshToken) {
            _ = try accounts.authCore.refresh(request, attemptHeader: nil, installationHeader: nil)
        }
        #expect(accounts.authCore.sessionIdentity(accessToken: tokens.accessToken) == nil)
    }

    @Test(arguments: ["ordinary", "durable-first", "durable-replay"])
    func realLegacyRefreshProducesAnActiveCurrentFamily(_ mode: String) async throws {
        let accounts = EmailLoginDirectory()
        let user = UUID().uuidString.lowercased()
        accounts.addAccount(id: user, email: "legacy-refresh-\(user)@slock.test", password: "realtime-password123")
        let oldAccess = "synthetic-old-access-\(UUID().uuidString.lowercased())"
        let oldRefresh = "synthetic-old-refresh-\(UUID().uuidString.lowercased())"
        let family = UUID().uuidString.lowercased()
        accounts.authProfileStore.state.withLock {
            $0.accountSurface.accessTokens[oldAccess] = user
            $0.accountSurface.sessions[oldRefresh] = LiveSession(userId: user, familyId: family)
        }
        let request = try JSONDecoder().decode(RefreshTokenRequest.self,
            from: JSONSerialization.data(withJSONObject: ["refreshToken": oldRefresh]))
        let attempt = mode == "ordinary" ? nil : "arf_1111111111111111"
        let installation = mode == "ordinary" ? nil : "ari_11111111111111111111111111111111"
        if mode == "durable-replay" {
            _ = try accounts.authCore.refresh(request, attemptHeader: attempt, installationHeader: installation)
            // Exact old-native durable receipt shape, whose first refresh did
            // not create a family row. The real replay must upgrade its facts.
            accounts.authProfileStore.state.withLock { $0.accountSurface.sessionFamilies.removeValue(forKey: family) }
        }
        let response = try accounts.authCore.refresh(request, attemptHeader: attempt, installationHeader: installation)
        #expect(accounts.authProfileStore.state.withLock { $0.accountSurface.sessionFamilies[family]?.userId } == user)
        #expect(accounts.authCore.sessionIdentity(accessToken: response.accessToken)?.familyId == family)
        #expect(accounts.authProfileStore.pushPrincipal(accessToken: oldAccess)?.familyId == nil)
        let realtime = try await RealtimeServer.start(auth: LedgerRealtimeAuth(authCore: accounts.authCore, membership: accounts.socketMembership))
        do {
            let socket = try await activeRealtimeConnect(port: realtime.port, token: response.accessToken)
            await socket.close()
        } catch { try? await realtime.close(); throw error }
        try await realtime.close()
    }
}
