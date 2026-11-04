import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func formerPrivateMemberCursorIsTheOnlyBoundaryReturned() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001105001"
    let ownerId = "11111111-1111-4111-8111-000001105001"
    let formerId = "11111111-1111-4111-8111-000001105002"
    accounts.addAccount(id: ownerId, email: "residue-owner@test.invalid", password: "password123")
    accounts.addAccount(id: formerId, email: "residue-former@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: formerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "residue-boundary", name: "Residue Boundary", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: formerId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "residue-private", creatorUserId: ownerId, type: "private")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: formerId)
    _ = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "before removal 1")
    let lastSeen = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "before removal 2")
    let receiverOwnedMax = accounts.messageSeqForTesting(messageId: lastSeen) ?? 0
    accounts.setUserChannelReadCursorForTesting(userId: formerId, channelId: channelId, seq: receiverOwnedMax)
    accounts.oauth.removeChannelHuman(channelId: channelId, userId: formerId)
    for index in 1...3 {
        _ = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "after removal \(index)")
    }
    let token = accounts.mintAccessTokenForTesting(userId: formerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func request(_ usePost: Bool, _ path: String, body: String? = nil) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                headers[.contentType] = "application/json"
                let response = try await client.send(usePost ? .post : .get, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                return (response, json)
            }
            let mutationId = "44444444-4444-4444-8444-000001105001"
            let payload = "{\"mutationId\":\"\(mutationId)\",\"kind\":\"channel_read_all\",\"scopeId\":\"\(channelId)\"}"
            let admission = try await request(true, "/api/read-mutations", body: payload)
            #expect(admission.0.status == .created)
            let replay = try await request(true, "/api/read-mutations", body: payload)
            #expect(replay.0.status == .ok)
            #expect(replay.1["outcome"] as? String == "ALREADY_TERMINAL")
            let ack = replay.1["ack"] as? [String: Any] ?? [:]
            let boundary = (ack["capturedBoundary"] as? [[String: Any]])?.first?["throughSeq"] as? Int ?? -1
            let ackMax = (ack["scopes"] as? [[String: Any]])?.first?["maxReadSeq"] as? Int ?? -1
            #expect(boundary <= receiverOwnedMax)
            #expect(ackMax <= receiverOwnedMax)
            let frontier = try await request(false, "/api/read-mutations/frontier?scopeIds=\(channelId)")
            let frontierMax = (frontier.1["scopes"] as? [[String: Any]])?.first?["maxReadSeq"] as? Int ?? -1
            #expect(frontierMax <= receiverOwnedMax)
        }
    }
}
