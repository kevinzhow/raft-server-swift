import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func migrationControlManifestAndChunkReceiptsValidateAndComplete() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001005001"
    let ownerId = "11111111-1111-4111-8111-000001005001"
    accounts.addAccount(id: ownerId, email: "chunk-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "chunk", name: "Chunk", ownerId: ownerId)
    let source = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "chunk-source")
    let target = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "chunk-target")
    accounts.linkComputerForTesting(serverId: serverId, machineId: source, online: true)
    let computerKey = try #require(accounts.computerAPIKeyForTesting(machineId: source))
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "chunk-agent", creatorUserId: ownerId)
    let ref = "mig_" + String(repeating: "e", count: 22)
    accounts.seedMachineMigrationForTesting(
        agentId: agent,
        serverId: serverId,
        supportRef: ref,
        revision: 1,
        state: "provisioning",
        sourceMachineId: source,
        targetMachineId: target,
        transportGeneration: "generation-1"
    )

    let sha0 = String(repeating: "a", count: 64)
    let sha1 = String(repeating: "b", count: 64)
    let manifest = "{\"schemaVersion\":1,\"bundle\":{\"chunks\":[{\"index\":0,\"offsetBytes\":0,\"sizeBytes\":1048576,\"sha256\":\"\(sha0)\"},{\"index\":1,\"offsetBytes\":1048576,\"sizeBytes\":10,\"sha256\":\"\(sha1)\"}]}}"

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func headers(_ bearer: String?) -> HTTPFields {
                var fields = HTTPFields()
                if let bearer { fields[.authorization] = "Bearer \(bearer)" }
                fields[.contentType] = "application/json"
                return fields
            }
            let base = "/internal/computer/agent-migrations/by-id/\(ref)/resumable"
            func putControl(_ body: String, bearer: String?) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(bearer), to: URI(string: "\(base)/control")) { request in
                    request.body = .init(string: body)
                }
            }
            func putReceipt(_ index: Int, _ sha: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(computerKey), to: URI(string: "\(base)/chunks/\(index)/receipt")) { request in
                    request.body = .init(string: "{\"sha256\":\"\(sha)\"}")
                }
            }

            #expect(try await putControl(manifest, bearer: nil).status == .unauthorized)
            #expect(try await putControl("{}", bearer: computerKey).status == .badRequest)
            // The manifest budget is 512 KB of manifest, not the old 16 KB parser cap.
            let oversized = "{\"bundle\":{\"chunks\":[]},\"pad\":\"\(String(repeating: "x", count: 513 * 1024))\"}"
            #expect(try await putControl(oversized, bearer: computerKey).status.code == 413)

            let accepted = try await putControl(manifest, bearer: computerKey)
            #expect(accepted.status == .ok)
            let acceptedBody = (try JSONSerialization.jsonObject(with: Data((accepted.body.string ?? "").utf8))) as? [String: Any]
            #expect(acceptedBody?["manifest"] != nil)
            #expect(try await putControl(manifest, bearer: computerKey).status == .ok)
            let conflict = try await putControl(manifest.replacingOccurrences(of: "\"index\":1", with: "\"index\":2"), bearer: computerKey)
            #expect(conflict.status == .conflict)
            #expect(((try JSONSerialization.jsonObject(with: Data((conflict.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "migration_control_manifest_conflict")

            let fetched = try await client.get(URI(string: "\(base)/control"), headers: headers(computerKey))
            #expect(fetched.status == .ok)

            let mismatch = try await putReceipt(0, sha1)
            #expect(mismatch.status == .conflict)
            #expect(((try JSONSerialization.jsonObject(with: Data((mismatch.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "migration_chunk_receipt_mismatch")
            #expect(try await putReceipt(9, sha0).status == .badRequest)
            #expect(try await putReceipt(0, sha0).status == .ok)

            let partial = try await client.get(URI(string: "\(base)/chunks"), headers: headers(computerKey))
            let partialBody = (try JSONSerialization.jsonObject(with: Data((partial.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(partialBody["chunks"] as? [Int] == [0, 1])
            #expect(partialBody["received"] as? [Int] == [0])
            #expect(partialBody["missing"] as? [Int] == [1])

            let incomplete = try await client.send(.post, headers: headers(computerKey), to: URI(string: "\(base)/upload-complete"))
            #expect(incomplete.status == .conflict)
            let incompleteBody = (try JSONSerialization.jsonObject(with: Data((incomplete.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(incompleteBody["code"] as? String == "migration_chunks_missing")
            #expect(incompleteBody["missing"] as? [Int] == [1])

            #expect(try await putReceipt(1, sha1).status == .ok)
            let complete = try await client.send(.post, headers: headers(computerKey), to: URI(string: "\(base)/upload-complete"))
            #expect(complete.status == .ok)
            #expect(((try JSONSerialization.jsonObject(with: Data((complete.body.string ?? "").utf8))) as? [String: Any])?["state"] as? String == "transfer_complete")

            let missingRef = "/internal/computer/agent-migrations/by-id/mig_zzzzzzzzzzzzzzzzzzzzzz/resumable/control"
            let missing = try await client.get(URI(string: missingRef), headers: headers(computerKey))
            #expect(missing.status == .notFound)
        }
    }
}
