import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func deletedThreadDoneRequiresOwnedResidueAndAValidFrontier() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001002001"
    let ownerId = "11111111-1111-4111-8111-000001002001"
    let outsiderId = "11111111-1111-4111-8111-000001002002"
    let ownerEmail = "deleted-done-owner@slock.test"
    let outsiderEmail = "deleted-done-outsider@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (outsiderId, outsiderEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "deleted-done", name: "Deleted Done", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "deleted-done", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "deleted-done")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let parent = accounts.addChannelMessageForTesting(channelId: channel, content: "thread parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parent)
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: channel, parentMessageId: parent, name: "thread")
    let residue = accounts.addChannelMessageForTesting(channelId: thread, content: "receiver-owned residue", senderId: ownerId)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: thread, messageId: residue)
    accounts.markChannelDeleted(channelId: thread)

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
            func done(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: "/api/channels/threads/done") { request in
                    request.body = .init(string: body)
                }
            }
            let owner = try await login(ownerEmail)
            let outsider = try await login(outsiderEmail)

            let malformed = try await done(owner, "{\"threadChannelId\":\"\(thread)\",\"throughActivitySeq\":null,\"frontierSpace\":\"storage\"}")
            #expect(malformed.status == .badRequest)
            #expect(((try JSONSerialization.jsonObject(with: Data((malformed.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "DONE_FRONTIER_REQUIRED")

            let denied = try await done(outsider, "{\"threadChannelId\":\"\(thread)\",\"frontierSpace\":\"storage\"}")
            #expect(denied.status == .notFound)

            let accepted = try await done(owner, "{\"threadChannelId\":\"\(thread)\",\"frontierSpace\":\"storage\"}")
            #expect(accepted.status == .ok)
            let acceptedBody = (try JSONSerialization.jsonObject(with: Data((accepted.body.string ?? "").utf8))) as? [String: Any]
            #expect(acceptedBody as NSDictionary? == ["ok": true] as NSDictionary)

            let explicit = try await done(owner, "{\"threadChannelId\":\"\(thread)\",\"throughActivitySeq\":\"1\",\"frontierSpace\":\"storage\"}")
            #expect(explicit.status == .ok)
            let explicitBody = (try JSONSerialization.jsonObject(with: Data((explicit.body.string ?? "").utf8))) as? [String: Any]
            #expect(explicitBody as NSDictionary? == ["ok": true] as NSDictionary)

            let missing = try await done(owner, "{\"threadChannelId\":\"99999999-9999-4999-8999-999999999999\",\"frontierSpace\":\"storage\"}")
            #expect(missing.status == .notFound)
        }
    }
}
