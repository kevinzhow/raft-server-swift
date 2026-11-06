import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func threadReadsPreferTheCanonicalThreadAmongDuplicates() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000990001"
    let ownerId = "11111111-1111-4111-8111-000000990001"
    let replierId = "11111111-1111-4111-8111-000000990002"
    let ownerEmail = "thread-dedup-owner@slock.test"
    let replierEmail = "thread-dedup-replier@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (replierId, replierEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-dedup", name: "Thread Dedup", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: replierId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "thread-dedup-parent", creatorUserId: ownerId)
    for id in [ownerId, replierId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "thread-dedup-parent")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let parent = accounts.addChannelMessageForTesting(channelId: channel, content: "dedup parent", senderId: ownerId)

    func makeThread(_ name: String) -> String {
        let thread = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parent)
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: thread,
            memberId: ownerId,
            kind: "thread",
            parentChannelId: channel,
            parentMessageId: parent,
            name: name
        )
        return thread
    }
    let stale = makeThread("thread-stale-parent")
    let staleReply = accounts.addChannelMessageForTesting(channelId: stale, content: "stale reply", senderId: ownerId)
    accounts.setHumanMessageCreatedAt(messageId: staleReply, createdAt: Date(timeIntervalSince1970: 1_900_000_000))

    let active = makeThread("thread-active-parent")
    let activeOne = accounts.addChannelMessageForTesting(channelId: active, content: "active reply one", senderId: ownerId)
    let activeTwo = accounts.addChannelMessageForTesting(channelId: active, content: "active reply two", senderId: replierId)
    accounts.setHumanMessageCreatedAt(messageId: activeOne, createdAt: Date(timeIntervalSince1970: 1_900_000_100))
    accounts.setHumanMessageCreatedAt(messageId: activeTwo, createdAt: Date(timeIntervalSince1970: 1_900_000_200))

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let summaries = try await client.get(URI(string: "/api/channels/\(channel)/threads"), headers: headers)
            #expect(summaries.status == .ok)
            let body = (try JSONSerialization.jsonObject(with: Data((summaries.body.string ?? "").utf8)) as? [String: Any]) ?? [:]
            #expect(Set(body.keys) == Set([parent]))
            let summary = try #require(body[parent] as? [String: Any])
            #expect(summary["threadChannelId"] as? String == active)
            #expect(summary["replyCount"] as? Int == 2)
            #expect(Set(summary["participantIds"] as? [String] ?? []) == Set([ownerId, replierId]))

            let info = try await client.get(URI(string: "/api/channels/\(channel)/threads/\(parent)"), headers: headers)
            #expect(info.status == .ok)
            let infoBody = try JSONSerialization.jsonObject(with: Data((info.body.string ?? "").utf8)) as? [String: Any]
            #expect(infoBody?["threadChannelId"] as? String == active)
            #expect(infoBody?["replyCount"] as? Int == 2)
            #expect(Set(infoBody?["participantIds"] as? [String] ?? []) == Set([ownerId, replierId]))
        }
    }
}
