import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct SearchContractFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerName: String
    let agentId: String
    let agentKey: String
    let publicChannel: String
    let privateChannel: String
    let hiddenChannel: String
}

private func makeSearchContractFixture(_ suffix: String) -> SearchContractFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001250\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001250\(suffix)"
    let ownerName = "search-contract-owner-\(suffix)"
    accounts.addAccount(id: ownerId, email: "\(ownerName)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "search-contract-\(suffix)", name: "Search Contract \(suffix)", ownerId: ownerId)
    func channel(_ name: String, type: String = "channel", agentMember: Bool) -> String {
        let id = accounts.oauth.createChannel(serverId: serverId, name: name, creatorUserId: ownerId, type: type)
        accounts.addPostableChannel(serverId: serverId, channelId: id, memberId: ownerId, kind: type, name: name)
        accounts.oauth.addChannelHuman(channelId: id, userId: ownerId)
        if agentMember { accounts.oauth.addChannelAgent(channelId: id, agentId: agentId) }
        return id
    }
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "SearchContractBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    let publicChannel = channel("search-contract-public-\(suffix)", agentMember: true)
    let privateChannel = channel("search-contract-private-\(suffix)", type: "private", agentMember: true)
    let hiddenChannel = channel("search-contract-hidden-\(suffix)", type: "private", agentMember: false)
    return SearchContractFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerName: ownerName,
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "search-contract-\(suffix)"),
        publicChannel: publicChannel,
        privateChannel: privateChannel,
        hiddenChannel: hiddenChannel
    )
}

private func searchContractGet(
    _ client: any Client,
    _ f: SearchContractFixture,
    query: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.agentKey)"
    let response = try await client.get(URI(string: "/internal/agent-api/search?\(query)"), headers: headers)
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@Test func agentSearchReturnsTypedRowsNewestFirst() async throws {
    let f = makeSearchContractFixture("901")
    let older = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: older, channelId: f.publicChannel, senderId: f.ownerId, content: "search-marker older row")
    f.accounts.setHumanMessageCreatedAt(messageId: older, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    let newer = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: newer, channelId: f.publicChannel, senderId: f.ownerId, content: "search-marker newer row")
    f.accounts.setHumanMessageCreatedAt(messageId: newer, createdAt: Date(timeIntervalSince1970: 1_800_000_100))

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let result = try await searchContractGet(
                client,
                f,
                query: "q=search-marker&channel=%23search-contract-public-901&sender=\(f.ownerName)&sort=recent&limit=5"
            )
            #expect(result.status == .ok)
            #expect(result.body["hasMore"] as? Bool == false)
            let rows = try #require(result.body["results"] as? [[String: Any]])
            #expect(rows.compactMap { $0["id"] as? String } == [newer, older])
            let row = rows[0]
            #expect(row["content"] as? String == "search-marker newer row")
            #expect(row["senderName"] as? String == f.ownerName)
            #expect(row["senderType"] as? String == "human")
            #expect(row["senderId"] as? String == f.ownerId)
            #expect(row["channelId"] as? String == f.publicChannel)
            #expect(row["channelName"] as? String == "search-contract-public-901")
            #expect(row["parentChannelId"] as? String == f.publicChannel)
            #expect(row["snippet"] is String)

            let limited = try await searchContractGet(client, f, query: "q=search-marker&sort=recent&limit=1")
            #expect((limited.body["results"] as? [[String: Any]] ?? []).count == 1)
            #expect(limited.body["hasMore"] as? Bool == true)
        }
    }
}

@Test func agentSearchSeesMemberPrivateChannelsAndParentAuthorizedThreads() async throws {
    let f = makeSearchContractFixture("902")
    let direct = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: direct, channelId: f.privateChannel, senderId: f.ownerId, content: "search-marker visible private direct")
    f.accounts.setHumanMessageCreatedAt(messageId: direct, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    let parent = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: parent, channelId: f.privateChannel, senderId: f.ownerId, content: "search-marker visible private parent")
    f.accounts.setHumanMessageCreatedAt(messageId: parent, createdAt: Date(timeIntervalSince1970: 1_800_000_100))
    let threadId = f.accounts.oauth.createThreadChannel(parentChannelId: f.privateChannel, parentMessageId: parent)
    f.accounts.addPostableChannel(
        serverId: f.serverId,
        channelId: threadId,
        memberId: f.ownerId,
        kind: "thread",
        parentChannelId: f.privateChannel,
        parentMessageId: parent,
        name: "thread"
    )
    let reply = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: reply, channelId: threadId, senderId: f.ownerId, content: "search-marker visible private thread reply")
    f.accounts.setHumanMessageCreatedAt(messageId: reply, createdAt: Date(timeIntervalSince1970: 1_800_000_200))
    let hidden = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: hidden, channelId: f.hiddenChannel, senderId: f.ownerId, content: "search-marker hidden private direct")
    f.accounts.setHumanMessageCreatedAt(messageId: hidden, createdAt: Date(timeIntervalSince1970: 1_800_000_300))

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let result = try await searchContractGet(client, f, query: "q=search-marker&sort=recent&limit=10")
            #expect(result.status == .ok)
            let rows = try #require(result.body["results"] as? [[String: Any]])
            #expect(rows.compactMap { $0["id"] as? String } == [reply, parent, direct])
            #expect(rows[0]["channelId"] as? String == threadId)
            #expect(rows[0]["parentChannelId"] as? String == f.privateChannel)
            #expect(rows.allSatisfy { row in (row["id"] as? String) != hidden }, "non-member private rows stay hidden")
            #expect(rows.allSatisfy { row in !((row["content"] as? String) ?? "").contains("hidden private") })
        }
    }
}

@Test func agentSearchCloaksHiddenHumanDirectorySenderLookups() async throws {
    let f = makeSearchContractFixture("903")
    let message = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: message, channelId: f.publicChannel, senderId: f.ownerId, content: "hidden directory owner message")
    f.accounts.setHideHumansFromMembers(serverId: f.serverId, hidden: true)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let hiddenLookup = try await searchContractGet(client, f, query: "sender=\(f.ownerName)&sort=recent")
            #expect(hiddenLookup.status == .notFound)
            #expect(hiddenLookup.body["errorCode"] as? String == "member_not_found")

            let unknownLookup = try await searchContractGet(client, f, query: "sender=missing-member-903&sort=recent")
            #expect(unknownLookup.status == hiddenLookup.status)
            let hiddenCode = hiddenLookup.body["errorCode"] as? String
            #expect(unknownLookup.body["errorCode"] as? String == hiddenCode)
        }
    }
}
