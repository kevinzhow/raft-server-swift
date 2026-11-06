import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func migrationTargetImportDrivesReadyToCompletedWithGenerations() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001006001"
    let ownerId = "11111111-1111-4111-8111-000001006001"
    accounts.addAccount(id: ownerId, email: "target-import-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "target-import", name: "Target Import", ownerId: ownerId)
    let source = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "import-source")
    let target = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "import-target")
    accounts.linkComputerForTesting(serverId: serverId, machineId: target, online: true)
    let targetKey = try #require(accounts.computerAPIKeyForTesting(machineId: target))
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "import-agent", creatorUserId: ownerId)
    accounts.setAgentMachineForTesting(agentId: agent, machineId: source)
    let ref = "mig_" + String(repeating: "f", count: 22)
    accounts.seedMachineMigrationForTesting(
        agentId: agent,
        serverId: serverId,
        supportRef: ref,
        revision: 1,
        state: "ready",
        sourceMachineId: source,
        targetMachineId: target,
        transportGeneration: "gen-ready"
    )
    let lostRef = "mig_" + String(repeating: "g", count: 22)
    accounts.seedMachineMigrationForTesting(
        agentId: agent,
        serverId: serverId,
        supportRef: lostRef,
        revision: 1,
        state: "in_transit",
        sourceMachineId: source,
        targetMachineId: target,
        transportGeneration: "gen-lost"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(targetKey)"
            headers[.contentType] = "application/json"
            let base = "/internal/computer/agent-migrations/by-id/\(ref)"
            func step(_ name: String, _ body: String) async throws -> (status: HTTPResponse.Status, migration: [String: Any]) {
                let response = try await client.send(.post, headers: headers, to: URI(string: "\(base)/\(name)")) { request in
                    request.body = .init(string: body)
                }
                let object = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                return (response.status, object["migration"] as? [String: Any] ?? [:])
            }

            let read = try await client.get(URI(string: base), headers: headers)
            #expect(read.status == .ok)
            let readView = try #require(((try JSONSerialization.jsonObject(with: Data((read.body.string ?? "").utf8))) as? [String: Any])?["migration"] as? [String: Any])
            #expect(readView["state"] as? String == "ready")
            #expect(readView["canDriveTargetImport"] as? Bool == true)
            #expect(readView["sourceMachineId"] as? String == source)
            #expect(readView["targetMachineId"] as? String == target)
            let readyGeneration = try #require(readView["migrationGeneration"] as? String)

            #expect(try await step("start-transfer", "{}").status == .badRequest)
            #expect(try await step("start-transfer", "{\"migrationGeneration\":\"stale\"}").status == .conflict)

            let started = try await step("start-transfer", "{\"migrationGeneration\":\"\(readyGeneration)\"}")
            #expect(started.status == .ok)
            #expect(started.migration["state"] as? String == "in_transit")
            let startedGeneration = try #require(started.migration["migrationGeneration"] as? String)
            #expect(startedGeneration != readyGeneration)

            #expect(try await step("flip-machine", "{\"migrationGeneration\":\"\(readyGeneration)\"}").status == .conflict)
            let flipped = try await step("flip-machine", "{\"migrationGeneration\":\"\(startedGeneration)\"}")
            #expect(flipped.status == .ok)
            #expect(flipped.migration["state"] as? String == "arriving")
            let flippedGeneration = try #require(flipped.migration["migrationGeneration"] as? String)
            #expect(flippedGeneration != startedGeneration)
            #expect(accounts.agentMachineIdForTesting(agentId: agent) == target)

            #expect(try await step("arrived", "{\"migrationGeneration\":\"\(flippedGeneration)\",\"reportPath\":\"\"}").status == .badRequest)
            let arrived = try await step("arrived", "{\"migrationGeneration\":\"\(flippedGeneration)\",\"reportPath\":\"migrations/report.json\",\"reportSha256\":\"sha256:arrival\"}")
            #expect(arrived.status == .ok)
            #expect(arrived.migration["state"] as? String == "completed")
            #expect(arrived.migration["migrationGeneration"] as? String != flippedGeneration)

            var lostHeaders = headers
            lostHeaders[.authorization] = "Bearer \(targetKey)"
            let lost = try await client.send(.post, headers: lostHeaders, to: URI(string: "/internal/computer/agent-migrations/by-id/\(lostRef)/transport-lost")) { request in
                request.body = .init(string: "{\"message\":\"MIGRATION_OBJECT_STORE_DOWNLOAD_RETRY_EXHAUSTED:404\",\"errorCode\":\"MIGRATION_OBJECT_STORE_SIZE_MISMATCH\"}")
            }
            #expect(lost.status == .ok)
            let lostView = try #require(((try JSONSerialization.jsonObject(with: Data((lost.body.string ?? "").utf8))) as? [String: Any])?["migration"] as? [String: Any])
            #expect(lostView["state"] as? String == "failed")
        }
    }
}
