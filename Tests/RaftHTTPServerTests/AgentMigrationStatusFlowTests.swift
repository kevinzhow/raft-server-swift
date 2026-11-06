import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func hostedMigrationStatusAndCancelUseThePublishedBodies() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001003001"
    let ownerId = "11111111-1111-4111-8111-000001003001"
    let memberId = "11111111-1111-4111-8111-000001003002"
    let ownerEmail = "migration-flow-owner@slock.test"
    let memberEmail = "migration-flow-member@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "migration-flow", name: "Migration Flow", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "migration-flow-agent", creatorUserId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "migration-source")
    let ref = "mig_" + String(repeating: "a", count: 22)
    accounts.seedHostedMigrationForTesting(
        agentId: agent,
        serverId: serverId,
        supportRef: ref,
        revision: 3,
        state: "in_transit",
        sourceMachineId: machine
    )

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
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let owner = try await login(ownerEmail)
            let member = try await login(memberEmail)

            let status = try await client.get(URI(string: "/api/agents/\(agent)/migration"), headers: headers(owner))
            #expect(status.status == .ok)
            let statusBody = (try JSONSerialization.jsonObject(with: Data((status.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(!statusBody.keys.contains("history"))
            let migration = try #require(statusBody["migration"] as? [String: Any])
            #expect(migration["migrationRef"] as? String == ref)
            #expect(migration["state"] as? String == "in_transit")
            #expect(migration["revision"] as? Int == 3)
            #expect(migration["targetKind"] as? String == "hosted")
            #expect(migration["targetMachineId"] is NSNull)
            #expect(!migration.keys.contains("migrationId"))

            let memberStatus = try await client.get(URI(string: "/api/agents/\(agent)/migration"), headers: headers(member))
            #expect(memberStatus.status == .forbidden)
            #expect(((try JSONSerialization.jsonObject(with: Data((memberStatus.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "not_supported")

            func cancel(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: URI(string: "/api/agents/\(agent)/migration/cancel")) { request in
                    request.body = .init(string: body)
                }
            }
            let memberDenied = try await cancel(member, "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":3}")
            #expect(memberDenied.status == .forbidden)
            let identity = try await cancel(owner, "{\"migrationId\":\"internal\",\"expectedRevision\":3}")
            #expect(identity.status == .badRequest)
            #expect(((try JSONSerialization.jsonObject(with: Data((identity.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "MIGRATION_REF_INVALID")
            let badRevision = try await cancel(owner, "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":0}")
            #expect(badRevision.status == .badRequest)
            #expect(((try JSONSerialization.jsonObject(with: Data((badRevision.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "MIGRATION_REVISION_INVALID")
            let notFound = try await cancel(owner, "{\"migrationRef\":\"mig_bbbbbbbbbbbbbbbbbbbbbb\",\"expectedRevision\":3}")
            #expect(notFound.status == .notFound)
            #expect(((try JSONSerialization.jsonObject(with: Data((notFound.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "MIGRATION_NOT_FOUND")
            let stale = try await cancel(owner, "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":2}")
            #expect(stale.status == .conflict)
            #expect(((try JSONSerialization.jsonObject(with: Data((stale.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "MIGRATION_REVISION_STALE")

            let canceled = try await cancel(owner, "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":3,\"reason\":\"owner requested\"}")
            #expect(canceled.status == .ok)
            let canceledMigration = try #require(((try JSONSerialization.jsonObject(with: Data((canceled.body.string ?? "").utf8))) as? [String: Any])?["migration"] as? [String: Any])
            #expect(canceledMigration["migrationRef"] as? String == ref)
            #expect(canceledMigration["state"] as? String == "canceled_pre_flip")
            #expect(canceledMigration["revision"] as? Int == 4)
            #expect(canceledMigration["cancelReason"] as? String == "owner requested")
            #expect(canceledMigration["cancelNeedsAttention"] as? Bool == false)
            #expect(canceledMigration["cancelDispatchAttempts"] as? Int == 1)
            #expect(canceledMigration["cancelLastDispatchAt"] is String)
            #expect(canceledMigration["cancelErrorCode"] is NSNull)

            let after = try await client.get(URI(string: "/api/agents/\(agent)/migration"), headers: headers(owner))
            #expect(((try JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8))) as? [String: Any])?["migration"] as? [String: Any] != nil)
            let terminal = try await cancel(owner, "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":4}")
            #expect(terminal.status == .conflict)
            #expect(((try JSONSerialization.jsonObject(with: Data((terminal.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "MIGRATION_NOT_CANCELABLE")
        }
    }
}
