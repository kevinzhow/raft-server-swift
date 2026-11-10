import Foundation
import RaftRealtime
import RaftPersistence
import RaftShared
import Testing
import TestSupport
@testable import RaftHTTP
@testable import RaftServer

private func activeRealtimePGProbe(_ f: AgentExecutionPostgresFixture, user: String, sockets: [ProtocolPGSocket]) async throws {
    let payload = "{\"nonce\":\"\(UUID().uuidString.lowercased())\"}"
    try await f.runtime.execute {
        f.realtimeServer.hub.emit(room: "user:\(user)", event: "test:session-live", payloadJSON: payload)
    }
    for socket in sockets { _ = try await socket.nextText { $0 == "42[\"test:session-live\",\(payload)]" } }
}

/// Dedicated PG and real published HTTP/NIO. No provider or machine peer is
/// launched. The fixture retains the actual production auth adapters and hub.
@Suite(.serialized) struct RealtimeActiveAuthPostgresTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RAFT_REALTIME_ACTIVE_AUTH_PG_ACCEPTANCE"] == "1"))
    func committedLogoutRetirementAndExistingPushScopesControlRealConnections() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["RAFT_REALTIME_ACTIVE_AUTH_TEST_DATABASE_URL"])
        let f = try await AgentExecutionPostgresFixture.start(databaseURL: url)
        var sockets: [ProtocolPGSocket] = []
        var racing: [Task<ProtocolPGSocket, any Error>] = []
        do {
            let loginBody = ProtocolPGObject(["email": .string(f.ownerEmail), "password": .string("protocol-only-password123")])
            let first = try await f.http("POST", "/api/auth/login", body: loginBody)
            let second = try await f.http("POST", "/api/auth/login", body: loginBody)
            try #require(first.status == 200 && second.status == 200)
            let aToken = try first.object().requireString("accessToken")
            let aRefresh = try first.object().requireString("refreshToken")
            let bToken = try second.object().requireString("accessToken")
            let aIdentity = try #require(f.runtime.withCommittedReadView { f.accounts.authCore.sessionIdentity(accessToken: aToken) })
            let aFamily = try #require(aIdentity.familyId)
            let bFamily = try #require(f.runtime.withCommittedReadView { f.accounts.authCore.sessionIdentity(accessToken: bToken)?.familyId })
            try #require(aFamily != bFamily)
            let legacy = "synthetic-pg-realtime-legacy-\(UUID().uuidString.lowercased())"
            let legacyRefresh = "synthetic-pg-legacy-refresh-\(UUID().uuidString.lowercased())"
            let legacyFamily = UUID().uuidString.lowercased()
            try await f.runtime.execute {
                // The actual native social-completion shape: familyless access,
                // a live refresh with family UUID, but no family metadata row.
                f.accounts.authProfileStore.state.withLock {
                    $0.accountSurface.accessTokens[legacy] = aIdentity.userId
                    $0.accountSurface.sessions[legacyRefresh] = LiveSession(userId: aIdentity.userId, familyId: legacyFamily)
                }
            }
            let legacyRotated = try await f.http("POST", "/api/auth/refresh", body: .init(["refreshToken": .string(legacyRefresh)]))
            try #require(legacyRotated.status == 200)
            let currentLegacyToken = try legacyRotated.object().requireString("accessToken")
            #expect(try f.runtime.withCommittedReadView { f.accounts.authCore.sessionIdentity(accessToken: currentLegacyToken)?.familyId } == legacyFamily)
            #expect(try f.runtime.withCommittedReadView { f.accounts.authCore.sessionIdentity(accessToken: legacy)?.familyId } == nil)
            let currentLegacy = try await activeRealtimeConnect(port: f.realtimeServer.port, token: currentLegacyToken); sockets.append(currentLegacy)
            let a = try await activeRealtimeConnect(port: f.realtimeServer.port, token: aToken, serverId: f.serverId); sockets.append(a)
            let b = try await activeRealtimeConnect(port: f.realtimeServer.port, token: bToken, serverId: f.serverId); sockets.append(b)
            let l = try await activeRealtimeConnect(port: f.realtimeServer.port, token: legacy); sockets.append(l)
            let memberToken = try await f.login(f.memberEmail)
            let member = try await activeRealtimeConnect(port: f.realtimeServer.port, token: memberToken, serverId: f.serverId); sockets.append(member)
            let memberId = try #require(f.runtime.withCommittedReadView { f.accounts.authCore.sessionIdentity(accessToken: memberToken)?.userId })

            // Stop the actual unrelated consumers before comparing SQL
            // revisions; this auth-only case does not need task/agent workers.
            await f.executionConnection.worker.stop()
            await f.pausePublications()
            let authKey = try DurableKey(domain: .authProfiles, aggregateID: "root")
            let beforeRows = try await f.observer.readSnapshot([authKey])
            let beforeSQL = try #require(beforeRows.first)
            // An ordinary domain throw commits by design. Only the existing
            // rollback-only marker guarantees actual discard and no hub close.
            let logoutRequest = try JSONDecoder().decode(RefreshTokenRequest.self,
                from: ProtocolPGObject(["refreshToken": .string(aRefresh)]).data)
            do {
                try await f.runtime.execute {
                    _ = f.accounts.authCore.logout(logoutRequest)
                    f.realtimeServer.hub.revokeFamily(userId: aIdentity.userId, familyId: aFamily)
                    DeferredEffects.markRollbackOnly()
                }
                Issue.record("The transaction must discard")
            } catch TransactionError.rollbackOnly {}
            let afterRows = try await f.observer.readSnapshot([authKey])
            let afterSQL = try #require(afterRows.first)
            #expect(afterSQL.revision == beforeSQL.revision)
            #expect(afterSQL.codecVersion == beforeSQL.codecVersion)
            let sameSQLPayload = afterSQL.json == beforeSQL.json
            // Never include the credential-bearing auth snapshot in diagnostics.
            #expect(sameSQLPayload, "Rollback must preserve the complete SQL auth payload")
            #expect(try f.runtime.withCommittedReadView { f.accounts.authCore.sessionIdentity(accessToken: aToken)?.familyId } == aFamily)
            try await activeRealtimePGProbe(f, user: aIdentity.userId, sockets: [a, b, l])

            // Actual refresh keeps the family and its established socket. The
            // predecessor remains the logout handle, including after rotation.
            let refreshed = try await f.http("POST", "/api/auth/refresh", body: .init(["refreshToken": .string(aRefresh)]))
            try #require(refreshed.status == 200)
            let successorToken = try refreshed.object().requireString("accessToken")
            let successorRefresh = try refreshed.object().requireString("refreshToken")
            let successor = try await activeRealtimeConnect(port: f.realtimeServer.port, token: successorToken, serverId: f.serverId); sockets.append(successor)
            try await activeRealtimePGProbe(f, user: aIdentity.userId, sockets: [a, successor, b, l])
            let resumeStart = b.count
            try await b.send("42[\"sync:resume\",{\"lastSeq\":1}]")
            _ = try await b.nextText(since: resumeStart) { $0.hasPrefix("42[\"sync:resume:response\",") }

            // Public HTTP/NIO overlap, without a scheduling hook or auth spy.
            // This is bounded pressure rather than a deterministic race claim.
            for _ in 0..<8 {
                racing.append(Task { try await activeRealtimeAttempt(port: f.realtimeServer.port, token: aToken, serverId: f.serverId) })
            }
            let logout = try await f.http("POST", "/api/auth/logout", body: .init(["refreshToken": .string(aRefresh)]))
            for attempt in racing {
                let socket = try await attempt.value
                sockets.append(socket)
                try await activeRealtimeClosed(socket)
            }
            #expect(logout.status == 200)
            #expect(String(decoding: logout.body, as: UTF8.self) == "{\"ok\":true}")
            try await activeRealtimeClosed(a)
            try await activeRealtimeClosed(successor)
            try await activeRealtimePGProbe(f, user: aIdentity.userId, sockets: [b, l, currentLegacy])
            try await activeRealtimePGProbe(f, user: memberId, sockets: [member])
            try await activeRealtimeRefused(port: f.realtimeServer.port, token: aToken, serverId: f.serverId)
            try await activeRealtimeRefused(port: f.realtimeServer.port, token: successorToken)
            #expect(try await f.http("POST", "/api/auth/refresh", body: .init(["refreshToken": .string(successorRefresh)])).status == 401)
            // The existing push primitive keeps its token-table-only contract.
            #expect(try f.runtime.withCommittedReadView { f.accounts.authProfileStore.pushPrincipal(accessToken: aToken)?.userId } == aIdentity.userId)
            let logoutReplay = try await f.http("POST", "/api/auth/logout", body: .init(["refreshToken": .string(aRefresh)]))
            #expect(logoutReplay.status == 200 && logoutReplay.body == logout.body)
            #expect(try await f.http("POST", "/api/auth/logout", body: .init([:])).status == 200)
            try await activeRealtimePGProbe(f, user: aIdentity.userId, sockets: [b, l, currentLegacy])

            // Preserve the pre-existing push-family close rule, which also
            // closes same-user legacy sockets. It is distinct from logout.
            let push = try await f.http("POST", "/api/push/registrations", token: bToken, body: .init([
                "installationId": .string("realtime-active-auth-pg"), "provider": .string("apns"),
                "env": .string("production"), "topic": .string("ai.slock.app"), "deviceToken": .string("synthetic-realtime-pg-device")]))
            try #require(push.status == 200)
            let capability = try push.object().requireString("revoke_capability")
            #expect(try await f.http("POST", "/api/push/family-revoke", body: .init(["capability": .string(capability)])).status == 204)
            try await activeRealtimeClosed(b)
            try await activeRealtimeClosed(l)
            // Push deletes token and family metadata in the SAME owner lock.
            // The former family token must never become a legacy principal.
            #expect(try f.runtime.withCommittedReadView {
                f.accounts.authProfileStore.pushPrincipal(accessToken: bToken) == nil
                    && f.accounts.authProfileStore.accessTokenFamilies[bToken] == nil
            })
            try await activeRealtimeRefused(port: f.realtimeServer.port, token: bToken)
            let legacyAgain = try await activeRealtimeConnect(port: f.realtimeServer.port, token: legacy); sockets.append(legacyAgain)
            try await activeRealtimePGProbe(f, user: aIdentity.userId, sockets: [currentLegacy, legacyAgain])
            try await activeRealtimePGProbe(f, user: memberId, sockets: [member])

            // The initial native bare/social refresh has no bound family facts.
            // Its real first logout therefore evicts its whole user, as Node's
            // null-family session does, rather than matching a synthetic UUID.
            let outsiderToken = try await f.login(f.outsiderEmail)
            let outsiderId = try #require(f.runtime.withCommittedReadView { f.accounts.authCore.sessionIdentity(accessToken: outsiderToken)?.userId })
            let bareAccess = "synthetic-bare-access-\(UUID().uuidString.lowercased())"
            let bareRefresh = "synthetic-bare-refresh-\(UUID().uuidString.lowercased())"
            let bareFamily = UUID().uuidString.lowercased()
            try await f.runtime.execute {
                f.accounts.authProfileStore.state.withLock {
                    $0.accountSurface.accessTokens[bareAccess] = outsiderId
                    $0.accountSurface.sessions[bareRefresh] = LiveSession(userId: outsiderId, familyId: bareFamily)
                }
            }
            let outsiderProper = try await activeRealtimeConnect(port: f.realtimeServer.port, token: outsiderToken); sockets.append(outsiderProper)
            let outsiderBare = try await activeRealtimeConnect(port: f.realtimeServer.port, token: bareAccess); sockets.append(outsiderBare)
            #expect(try await f.http("POST", "/api/auth/logout", body: .init(["refreshToken": .string(bareRefresh)])).status == 200)
            try await activeRealtimeClosed(outsiderProper)
            try await activeRealtimeClosed(outsiderBare)
            try await activeRealtimePGProbe(f, user: aIdentity.userId, sockets: [currentLegacy, legacyAgain])

            // A real successful retirement closes ALL of its user's families,
            // legacy sessions, and server scopes, while another user survives.
            try await f.runtime.execute { f.accounts.configureAuthCoreForTesting { $0.releaseBranch = "staging" } }
            let email = "retire-realtime-\(UUID().uuidString.lowercased())@mail.build"
            let retirementCapability = "synthetic-realtime-retire-capability-1234567890"
            // Known local verified-account/capability fixture facts, exactly
            // like the shared PG fixture's original account seeds. This case
            // does not claim registration or email delivery/verification.
            let retireUser = UUID().uuidString.lowercased()
            let retireServer = UUID().uuidString.lowercased()
            let retireLegacy = "synthetic-retire-legacy-\(UUID().uuidString.lowercased())"
            try await f.runtime.execute {
                f.accounts.addAccount(id: retireUser, email: email, password: "realtime-password123")
                f.accounts.markEmailVerified(userId: retireUser)
                f.accounts.oauth.addOwnedServer(id: retireServer, slug: "realtime-retire", name: "Realtime retire", ownerId: retireUser)
                f.accounts.authProfileStore.state.withLock {
                    $0.accountSurface.accounts[email]?.stagingSelfAccountCapabilityHash = AuthTokenCodec.sha256(retirementCapability)
                    $0.accountSurface.accessTokens[retireLegacy] = retireUser
                }
            }
            let firstRetireLogin = try await f.http("POST", "/api/auth/login", body: .init(["email": .string(email), "password": .string("realtime-password123")]))
            try #require(firstRetireLogin.status == 200)
            let retireToken = try firstRetireLogin.object().requireString("accessToken")
            let another = try await f.http("POST", "/api/auth/login", body: .init(["email": .string(email), "password": .string("realtime-password123")]))
            try #require(another.status == 200)
            let anotherToken = try another.object().requireString("accessToken")
            let r1 = try await activeRealtimeConnect(port: f.realtimeServer.port, token: retireToken, serverId: retireServer); sockets.append(r1)
            let r2 = try await activeRealtimeConnect(port: f.realtimeServer.port, token: anotherToken); sockets.append(r2)
            let r3 = try await activeRealtimeConnect(port: f.realtimeServer.port, token: retireLegacy); sockets.append(r3)
            let invalid = try await f.http("POST", "/api/auth/staging-self-account/retire", token: retireToken,
                body: .init(["userId": .string(retireUser), "capability": .string("wrong-retirement-capability-1234567890")]))
            #expect(invalid.status == 403)
            try await activeRealtimePGProbe(f, user: retireUser, sockets: [r1, r2, r3])
            let retireBody = ProtocolPGObject(["userId": .string(retireUser), "capability": .string(retirementCapability)])
            let retired = try await f.http("POST", "/api/auth/staging-self-account/retire", token: retireToken, body: retireBody)
            try #require(retired.status == 200)
            #expect(try retired.object().object("receipt")?.string("terminalState") == "retired")
            for socket in [r1, r2, r3] { try await activeRealtimeClosed(socket) }
            for token in [retireToken, anotherToken, retireLegacy] { try await activeRealtimeRefused(port: f.realtimeServer.port, token: token) }
            let retiredReplay = try await f.http("POST", "/api/auth/staging-self-account/retire", token: retireToken, body: retireBody)
            #expect(retiredReplay.status == 200 && retiredReplay.body == retired.body)
            try await activeRealtimePGProbe(f, user: aIdentity.userId, sockets: [legacyAgain])
            try await activeRealtimePGProbe(f, user: memberId, sockets: [member])
        } catch {
            for attempt in racing { if let socket = try? await attempt.value { await socket.close() } }
            for socket in sockets { await socket.close() }
            await f.close()
            throw error
        }
        for socket in sockets { await socket.close() }
        await f.close()
    }
}
