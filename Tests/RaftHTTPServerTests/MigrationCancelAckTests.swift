import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func migrationCancelAckChecksRoleAndGenerations() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001007001"
    let ownerId = "11111111-1111-4111-8111-000001007001"
    let ownerEmail = "cancel-ack-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "cancel-ack", name: "Cancel Ack", ownerId: ownerId)
    let source = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "ack-source")
    let target = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "ack-target")
    accounts.linkComputerForTesting(serverId: serverId, machineId: source, online: true)
    accounts.linkComputerForTesting(serverId: serverId, machineId: target, online: true)
    let sourceKey = try #require(accounts.computerAPIKeyForTesting(machineId: source))
    let targetKey = try #require(accounts.computerAPIKeyForTesting(machineId: target))
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "ack-agent", creatorUserId: ownerId)
    let ref = "mig_" + String(repeating: "h", count: 22)
    accounts.seedMachineMigrationForTesting(
        agentId: agent,
        serverId: serverId,
        supportRef: ref,
        revision: 1,
        state: "in_transit",
        sourceMachineId: source,
        targetMachineId: target,
        transportGeneration: "route-transport-generation"
    )
    let postFlipRef = "mig_" + String(repeating: "i", count: 22)
    accounts.seedMachineMigrationForTesting(
        agentId: agent,
        serverId: serverId,
        supportRef: postFlipRef,
        revision: 3,
        state: "canceled_post_flip",
        sourceMachineId: source,
        targetMachineId: target,
        transportGeneration: "post-flip-generation"
    )
    accounts.seedMachineMigrationCancelStateForTesting(
        migrationRef: postFlipRef,
        state: "canceled_post_flip",
        cancelGeneration: "post-flip-cancel",
        cancelTransportGeneration: "post-flip-generation",
        disposition: "post_flip_target_authoritative"
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
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let ownerToken = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var ownerHeaders = HTTPFields()
            ownerHeaders[.authorization] = "Bearer \(ownerToken)"
            ownerHeaders[.contentType] = "application/json"
            ownerHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let cancel = try await client.send(.post, headers: ownerHeaders, to: URI(string: "/api/agents/\(agent)/migration/cancel")) { request in
                request.body = .init(string: "{\"migrationRef\":\"\(ref)\",\"expectedRevision\":1}")
            }
            #expect(cancel.status == .ok)
            let generations = try #require(accounts.machineMigrationCancelGenerationsForTesting(migrationRef: ref))

            func ack(_ key: String, _ pathRef: String, _ body: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: URI(string: "/internal/computer/agent-migrations/by-id/\(pathRef)/cancel-ack")) { request in
                    request.body = .init(string: body)
                }
            }
            let stale = try await ack(sourceKey, ref, "{\"migrationRef\":\"\(ref)\",\"transportGeneration\":\"stale\",\"cancelGeneration\":\"\(generations.cancel)\",\"role\":\"source\",\"outcome\":\"cleaned\"}")
            #expect(stale.status == .conflict)
            #expect(((try JSONSerialization.jsonObject(with: Data((stale.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "migration_generation_stale")
            let staleCancel = try await ack(sourceKey, ref, "{\"migrationRef\":\"\(ref)\",\"transportGeneration\":\"\(generations.transport)\",\"cancelGeneration\":\"stale\",\"role\":\"source\",\"outcome\":\"cleaned\"}")
            #expect(staleCancel.status == .conflict)
            #expect(((try JSONSerialization.jsonObject(with: Data((staleCancel.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "migration_cancel_generation_stale")
            let missing = try await ack(sourceKey, ref, "{\"migrationRef\":\"\(ref)\"}")
            #expect(missing.status == .badRequest)
            #expect(((try JSONSerialization.jsonObject(with: Data((missing.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "migration_cancel_ack_input_required")

            let sourceAck = try await ack(sourceKey, ref, "{\"migrationRef\":\"\(ref)\",\"transportGeneration\":\"\(generations.transport)\",\"cancelGeneration\":\"\(generations.cancel)\",\"role\":\"source\",\"outcome\":\"cleaned\"}")
            #expect(sourceAck.status == .ok)
            #expect(((try JSONSerialization.jsonObject(with: Data((sourceAck.body.string ?? "").utf8))) as? [String: Any])?["migration"] as? [String: Any] != nil)
            let targetAck = try await ack(targetKey, ref, "{\"migrationRef\":\"\(ref)\",\"transportGeneration\":\"\(generations.transport)\",\"cancelGeneration\":\"\(generations.cancel)\",\"role\":\"target\",\"outcome\":\"cleaned\"}")
            #expect(targetAck.status == .ok)

            let postFlip = try await ack(targetKey, postFlipRef, "{\"migrationRef\":\"\(postFlipRef)\",\"transportGeneration\":\"post-flip-generation\",\"cancelGeneration\":\"post-flip-cancel\",\"role\":\"target\",\"outcome\":\"cleaned\"}")
            #expect(postFlip.status == .conflict)
            #expect(((try JSONSerialization.jsonObject(with: Data((postFlip.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "migration_cancel_outcome_mismatch")

            var sourceHeaders = HTTPFields()
            sourceHeaders[.authorization] = "Bearer \(sourceKey)"
            sourceHeaders[.contentType] = "application/json"
            let missingReceipt = try await client.send(.post, headers: sourceHeaders, to: URI(string: "/internal/computer/agent-migrations/by-id/\(ref)/resumable/source-quiesced")) { request in
                request.body = .init(string: "{}")
            }
            #expect(missingReceipt.status == .badRequest)
            #expect(((try JSONSerialization.jsonObject(with: Data((missingReceipt.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "migration_source_quiesce_receipt_required")
            let quiesced = try await client.send(.post, headers: sourceHeaders, to: URI(string: "/internal/computer/agent-migrations/by-id/\(ref)/resumable/source-quiesced")) { request in
                request.body = .init(string: "{\"receipt\":{\"pid\":42,\"generation\":\"route-transport-generation\"}}")
            }
            #expect(quiesced.status == .ok)
            let quiesceBody = (try JSONSerialization.jsonObject(with: Data((quiesced.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(quiesceBody["migrationGeneration"] is String)
            #expect(quiesceBody["leaseId"] is String)

            let progress = try await client.send(.post, headers: sourceHeaders, to: URI(string: "/internal/computer/agent-migrations/by-id/\(ref)/resumable/source-progress")) { request in
                request.body = .init(string: "{\"phase\":\"copying\",\"bytes\":123}")
            }
            #expect(progress.status == .ok)
            let progressBody = (try JSONSerialization.jsonObject(with: Data((progress.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(progressBody["advanced"] as? Bool == true)
            #expect(progressBody["prepDeadlineAt"] is String)
        }
    }
}
