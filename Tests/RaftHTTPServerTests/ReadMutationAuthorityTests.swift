import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func readMutationDerivesAuthorityEnforcesReplayAndExposesFrontier() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111622"
    let serverId = "33333333-3333-4333-8333-333333333666"
    accounts.addAccount(id: userId, email: "read-api@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "read-mutation-api", name: "Read Mutation API", ownerId: userId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "read-mutation-room", creatorUserId: userId, type: "channel")
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    let mutationId = "9f2e6f5c-4b1a-4c55-9f24-8f1d2c3b4a50"
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func headers() -> HTTPFields {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                headers[.contentType] = "application/json"
                return headers
            }
            func post(_ body: [String: Any]) async throws -> (ClientResponse, [String: Any]) {
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers(), to: URI(string: "/api/read-mutations")) { request in
                    request.body = .init(data: data)
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let admitted = try await post([
                "mutationId": mutationId, "kind": "global_read_all",
                "serverId": UUID().uuidString, "principalId": UUID().uuidString,
            ])
            #expect(admitted.0.status == .created)
            #expect(admitted.1["outcome"] as? String == "ADMITTED")
            #expect(admitted.1["serverId"] as? String == serverId)
            #expect(admitted.1["principalId"] as? String == userId)
            #expect(admitted.1["authoritySeq"] as? Int == 1)

            let replay = try await post(["mutationId": mutationId, "kind": "global_read_all"])
            #expect(replay.0.status == .ok)
            #expect(replay.1["outcome"] as? String == "ALREADY_ADMITTED")

            let mismatch = try await post(["mutationId": mutationId, "kind": "channel_read_all", "scopeId": channelId])
            #expect(mismatch.0.status == .conflict)
            #expect(mismatch.1["code"] as? String == "MUTATION_ID_PAYLOAD_MISMATCH")

            let frontier = try await client.get(URI(string: "/api/read-mutations/frontier"), headers: headers())
            let frontierBody = (try? JSONSerialization.jsonObject(with: Data((frontier.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(frontierBody["nextAuthoritySeq"] as? Int == 2)
            #expect(frontierBody["lastTerminalAuthoritySeq"] as? Int == 0)
            #expect(frontierBody["snapshotUpperAuthoritySeq"] as? Int == 1)
            let items = frontierBody["items"] as? [[String: Any]] ?? []
            #expect(items.map { "\($0["mutationId"] as? String ?? ""):\($0["authoritySeq"] as? Int ?? -1):\($0["state"] as? String ?? "")" } == ["\(mutationId):1:admitted"])

            let invalidUuid = try await post(["mutationId": "00000000-0000-1000-8000-000000000000", "kind": "global_read_all"])
            #expect(invalidUuid.0.status == .badRequest)
            #expect(invalidUuid.1["code"] as? String == "INVALID_MUTATION_ID")

            let missingScope = try await post(["mutationId": UUID().uuidString, "kind": "channel_read_all", "scopeId": UUID().uuidString])
            #expect(missingScope.0.status == .notFound)

            let internalDone = try await post([
                "mutationId": UUID().uuidString, "kind": "done",
                "targetKind": "channel", "scopeId": channelId, "throughSeq": "1",
            ])
            #expect(internalDone.0.status == .badRequest)
            #expect(internalDone.1["code"] as? String == "INVALID_MUTATION_PAYLOAD")
        }
    }
}

@Test func replayReachesIdentityDedupeAfterScopeMembershipRevoked() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111623"
    let serverId = "33333333-3333-4333-8333-333333333667"
    accounts.addAccount(id: userId, email: "read-replay-revoke@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "read-replay-revoke", name: "Read Replay Revoke", ownerId: userId)
    let scopeId = accounts.oauth.createChannel(serverId: serverId, name: "read-replay-private", creatorUserId: userId, type: "private")
    accounts.oauth.addChannelHuman(channelId: scopeId, userId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    let mutationId = "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            headers[.contentType] = "application/json"
            func post(_ body: [String: Any]) async throws -> (ClientResponse, [String: Any]) {
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/read-mutations")) { request in
                    request.body = .init(data: data)
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let first = try await post(["mutationId": mutationId, "kind": "channel_read_all", "scopeId": scopeId])
            #expect(first.0.status == .created)
            accounts.oauth.removeChannelHuman(channelId: scopeId, userId: userId)

            let replay = try await post(["mutationId": mutationId, "kind": "channel_read_all", "scopeId": scopeId])
            #expect(replay.0.status == .ok)
            #expect(replay.1["outcome"] as? String == "ALREADY_ADMITTED")

            let mismatch = try await post(["mutationId": mutationId, "kind": "row_read", "scopeId": scopeId, "throughSeq": 1])
            #expect(mismatch.0.status == .conflict)
            #expect(mismatch.1["code"] as? String == "MUTATION_ID_PAYLOAD_MISMATCH")

            let fresh = try await post(["mutationId": UUID().uuidString, "kind": "channel_read_all", "scopeId": scopeId])
            #expect(fresh.0.status == .notFound)
        }
    }
}
