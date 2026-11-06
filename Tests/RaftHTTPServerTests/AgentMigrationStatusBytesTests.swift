import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The three migrated agent-migration-status routes publish the legacy bytes:
/// the same member order, the same literals and the same error object order.
/// Parsing the JSON in a test would pass even if `JSONEncoder` reordered the
/// object on Linux, so these assertions compare the body strings directly.

@Test func agentMigrationStatusPublishesTheLegacyMigrationBytes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111621"
    let serverId = "33333333-3333-4333-8333-333333333667"
    accounts.addAccount(id: ownerId, email: "migration-bytes@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "migration-bytes", name: "Migration Bytes", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "migration-bytes-agent", creatorUserId: ownerId)
    let source = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "bytes-source")
    let target = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "bytes-target")
    let ref = "mig_" + String(repeating: "c", count: 22)
    accounts.seedMachineMigrationForTesting(
        agentId: agent,
        serverId: serverId,
        supportRef: ref,
        revision: 5,
        state: "in_transit",
        sourceMachineId: source,
        targetMachineId: target,
        transportGeneration: "bytes-transport-generation"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"migration-bytes@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.get(URI(string: "/api/agents/\(agent)/migration"), headers: headers)
            #expect(response.status == .ok)

            let expected = #"{"migration":{"migrationRef":"\#(ref)","agentId":"\#(agent)","state":"in_transit","revision":5,"sourceMachineId":"\#(source)","targetKind":"computer","targetMachineId":"\#(target)","provider":"object_store","failureReason":null,"autoStartFailureStage":null,"autoStartFailureCode":null,"abortReason":null,"transportErrorCode":null,"transportErrorMessage":null,"transportLostAt":null,"transportTeardownAt":null,"readyAt":null,"flippedAt":null,"arrivedAt":null,"completedAt":null,"abortedAt":null,"canceledAt":null,"cancelReason":null,"cancelNeedsAttention":false,"cancelDispatchAttempts":0,"cancelLastDispatchAt":null,"cancelErrorCode":null,"cancelErrorMessage":null}}"#
            #expect(response.body.string == expected)
            #expect(response.headers[.contentType] == "application/json; charset=utf-8")
            #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(response.headers[.contentLength] == String(expected.utf8.count))
        }
    }
}

@Test func externalDiagnosticsPublishesTheLegacyDiagnosticsBytes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111622"
    let serverId = "33333333-3333-4333-8333-333333333668"
    accounts.addAccount(id: ownerId, email: "diagnostics-bytes@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "diagnostics-bytes", name: "Diagnostics Bytes", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(
        serverId: serverId,
        name: "diagnostics-bytes-agent",
        creatorUserId: ownerId,
        runtime: "external"
    )
    let activatedAt = ISO8601DateFormatter().date(from: "2026-09-03T00:00:00Z")!
    accounts.setAgentProviderPositionForTesting(
        agentId: agent,
        state: "active",
        providerAgentId: "ap_agent_1",
        activatedAt: activatedAt
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"diagnostics-bytes@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.get(
                URI(string: "/api/agents/\(agent)/external-diagnostics"),
                headers: headers
            )
            #expect(response.status == .ok)

            let expected = #"{"agentId":"\#(agent)","runtime":"external","provider":{"kind":"antiproton","state":"active","providerAgentId":"ap_agent_1","syncPending":false,"lastErrorCode":null,"lastErrorAt":null,"activatedAt":"2026-09-03T00:00:00.000Z"},"presence":{"lastSeenAt":null,"online":false,"onlineWindowMs":120000},"status":{"activity":"idle","statusProtocolAdoptedAt":null},"push":{"registered":false,"enabled":false,"endpointHost":null,"disabledReason":null,"disabledAt":null,"consecutiveFailures":0,"lastAttemptAt":null,"lastDeliveryAt":null,"lastError":null,"nextAttemptAt":null},"events":{"lastCursorPullAt":null,"pendingCursorAckCount":0},"connections":[{"provider":"github","state":"not_applicable","account":null,"reason":null}]}"#
            #expect(response.body.string == expected)
            #expect(response.headers[.contentType] == "application/json; charset=utf-8")
            #expect(response.headers[.contentLength] == String(expected.utf8.count))
        }
    }
}

@Test func agentMigrationErrorsKeepTheCodeBeforeErrorBytes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111623"
    let memberId = "11111111-1111-4111-8111-111111111624"
    let serverId = "33333333-3333-4333-8333-333333333669"
    accounts.addAccount(id: ownerId, email: "migration-errors-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "migration-errors-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "migration-errors", name: "Migration Errors", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "migration-errors-agent", creatorUserId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String?) -> HTTPFields {
                var fields = HTTPFields()
                if let token { fields[.authorization] = "Bearer \(token)" }
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let owner = try await login("migration-errors-owner@slock.test")
            let member = try await login("migration-errors-member@slock.test")

            let unauthenticated = try await client.get(
                URI(string: "/api/agents/\(agent)/migration"),
                headers: headers(nil)
            )
            #expect(unauthenticated.status == .unauthorized)
            #expect(unauthenticated.body.string == #"{"error":"Unauthorized"}"#)

            let denied = try await client.send(
                .post,
                headers: headers(member),
                to: URI(string: "/api/agents/\(agent)/migration/cancel")
            ) { request in
                request.body = .init(string: #"{"migrationRef":"mig_cccccccccccccccccccccc","expectedRevision":1}"#)
            }
            #expect(denied.status == .forbidden)
            #expect(denied.body.string == #"{"code":"not_supported","error":"Agent migration cancel requires creator or server admin authority"}"#)

            let internalIdentity = try await client.send(
                .post,
                headers: headers(owner),
                to: URI(string: "/api/agents/\(agent)/migration/cancel")
            ) { request in
                request.body = .init(string: #"{"migrationId":"internal","expectedRevision":1}"#)
            }
            #expect(internalIdentity.status == .badRequest)
            #expect(internalIdentity.body.string == #"{"code":"MIGRATION_REF_INVALID","error":"migrationRef is required"}"#)

            let fractional = try await client.send(
                .post,
                headers: headers(owner),
                to: URI(string: "/api/agents/\(agent)/migration/cancel")
            ) { request in
                request.body = .init(string: #"{"migrationRef":"mig_cccccccccccccccccccccc","expectedRevision":1.5}"#)
            }
            #expect(fractional.status == .badRequest)
            #expect(fractional.body.string == #"{"code":"MIGRATION_REVISION_INVALID","error":"expectedRevision must be a positive integer"}"#)

            // A body sent without a JSON `Content-Type` still decodes, exactly
            // like the retired raw parser.
            var headerless = headers(owner)
            headerless[.contentType] = nil
            let headerlessBody = try await client.send(
                .post,
                headers: headerless,
                to: URI(string: "/api/agents/\(agent)/migration/cancel")
            ) { request in
                request.body = .init(string: #"{"expectedRevision":1}"#)
            }
            #expect(headerlessBody.status == .badRequest)
            #expect(headerlessBody.body.string == #"{"code":"MIGRATION_REF_INVALID","error":"migrationRef is required"}"#)
        }
    }
}
