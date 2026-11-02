import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func readAllRetiresOnlyReceiverOwnedResidueAndKeepsTheOpaque404() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001011001"
    let otherServerId = "33333333-3333-4333-8333-000001011002"
    let ownerId = "11111111-1111-4111-8111-000001011001"
    let exMemberId = "11111111-1111-4111-8111-000001011002"
    let strangerId = "11111111-1111-4111-8111-000001011003"
    let exEmail = "residue-ex@slock.test"
    let strangerEmail = "residue-stranger@slock.test"
    for (id, email) in [(ownerId, "residue-owner@slock.test"), (exMemberId, exEmail), (strangerId, strangerEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "residue", name: "Residue", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "residue-other", name: "Residue Other", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: exMemberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: strangerId, role: "member")
    let room = accounts.oauth.createChannel(serverId: serverId, name: "residue-room", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: room, memberId: ownerId, kind: "private", name: "residue-room")
    accounts.addPostableChannel(serverId: serverId, channelId: room, memberId: exMemberId, kind: "private", name: "residue-room")
    accounts.oauth.addChannelHuman(channelId: room, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: room, userId: exMemberId)
    let first = accounts.oauth.createMessageRecord(channelId: room, content: "while a member", senderId: ownerId)
    accounts.addInboxFactForTesting(receiverId: exMemberId, serverId: serverId, channelId: room, messageId: first.id)
    accounts.removeChannelMember(channelId: room, memberId: exMemberId)
    accounts.oauth.removeChannelHuman(channelId: room, userId: exMemberId)
    let after = accounts.oauth.createMessageRecord(channelId: room, content: "after removal", senderId: ownerId)

    let otherChannel = accounts.oauth.createChannel(serverId: otherServerId, name: "residue-elsewhere", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: otherServerId, channelId: otherChannel, memberId: ownerId, kind: "private", name: "residue-elsewhere")
    accounts.oauth.addChannelHuman(channelId: otherChannel, userId: ownerId)

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
            func readAll(_ token: String, _ id: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.post, headers: headers, to: URI(string: "/api/channels/\(id)/read-all")) { request in
                    request.body = .init(string: "{}")
                }
            }
            let exMember = try await login(exEmail)
            let stranger = try await login(strangerEmail)

            let retired = try await readAll(exMember, room)
            #expect(retired.status == .ok)
            let retiredBody = (try JSONSerialization.jsonObject(with: Data((retired.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(retiredBody["ok"] as? Bool == true)
            #expect(Set(retiredBody.keys).isSubset(of: Set(["ok", "seq", "readStateVersion"])))
            #expect(retiredBody["seq"] as? Int == first.seq)
            #expect(retiredBody["seq"] as? Int != after.seq)

            let replay = try await readAll(exMember, room)
            #expect(replay.status == .ok)

            let secret = accounts.oauth.createChannel(serverId: serverId, name: "residue-secret", creatorUserId: ownerId, type: "private")
            accounts.addPostableChannel(serverId: serverId, channelId: secret, memberId: ownerId, kind: "private", name: "residue-secret")
            accounts.oauth.addChannelHuman(channelId: secret, userId: ownerId)
            let real = try await readAll(stranger, secret)
            let missing = try await readAll(stranger, "99999999-9999-4999-8999-999999999999")
            let cross = try await readAll(stranger, otherChannel)
            #expect(real.status == .notFound)
            #expect(missing.status == .notFound)
            #expect(cross.status == .notFound)
            #expect((real.body.string ?? "") == "{\"error\":\"Channel not found\"}")
            #expect((missing.body.string ?? "") == (real.body.string ?? ""))
            #expect((cross.body.string ?? "") == (real.body.string ?? ""))
        }
    }
}
