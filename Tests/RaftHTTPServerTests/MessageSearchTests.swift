import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct SearchFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let ownerId: String
    let ownerEmail: String
}

private func makeSearchFixture(suffix: String) -> SearchFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 980_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 980_000 + number)
    let ownerEmail = "search-owner-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "search-\(suffix)", name: "Search", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "search-channel-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "search-channel-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    return SearchFixture(accounts: accounts, serverId: serverId, channelId: channel, ownerId: ownerId, ownerEmail: ownerEmail)
}

private func searchLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func searchHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func searchBody(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func searchResults(_ response: ClientResponse) throws -> [[String: Any]] {
    try searchBody(response)["results"] as? [[String: Any]] ?? []
}

@Test func messageSearchSupportsRecentSortAndRejectsUnknownSorts() async throws {
    let fixture = makeSearchFixture(suffix: "991")
    let old = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.channelId,
        content: "chronos chronos chronos chronos chronos older high relevance",
        senderId: fixture.ownerId,
        createdAt: Date(timeIntervalSince1970: 1_777_000_000)
    )
    let recent = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.channelId,
        content: "chronos newer low relevance",
        senderId: fixture.ownerId,
        createdAt: Date(timeIntervalSince1970: 1_777_100_000)
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await searchLogin(client, email: fixture.ownerEmail)
            let headers = searchHeaders(token, fixture.serverId)
            let relevance = try await client.get(URI(string: "/api/messages/search?q=chronos&limit=2"), headers: headers)
            #expect(relevance.status == .ok)
            #expect(try searchResults(relevance).first?["id"] as? String == old)

            let recentSort = try await client.get(URI(string: "/api/messages/search?q=chronos&sort=recent&limit=2"), headers: headers)
            #expect(recentSort.status == .ok)
            #expect(try searchResults(recentSort).first?["id"] as? String == recent)

            let invalid = try await client.get(URI(string: "/api/messages/search?q=chronos&sort=fancy"), headers: headers)
            #expect(invalid.status == .badRequest)
        }
    }
}

@Test func messageSearchFallsBackToRelaxedCJKMatching() async throws {
    let fixture = makeSearchFixture(suffix: "992")
    let target = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.channelId,
        content: "今晚真收工 Eric 的八发全中账我背书，各位辛苦。",
        senderId: fixture.ownerId
    )
    for index in 0..<24 {
        _ = fixture.accounts.addChannelMessageForTesting(
            channelId: fixture.channelId,
            content: String(format: "今晚 fallback decoy %02d", index),
            senderId: fixture.ownerId
        )
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await searchLogin(client, email: fixture.ownerEmail)
            let query = "今晚八发刚收工，明天开".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let response = try await client.get(
                URI(string: "/api/messages/search?q=\(query)&limit=20"),
                headers: searchHeaders(token, fixture.serverId)
            )
            #expect(response.status == .ok)
            let body = try searchBody(response)
            let results = body["results"] as? [[String: Any]] ?? []
            #expect(results.first?["id"] as? String == target)
            #expect((results.first?["content"] as? String)?.contains("今晚真收工") == true)
            #expect(results.count == 20)
            #expect(body["hasMore"] as? Bool == false)
        }
    }
}

@Test func messageSearchScopesByChannelSenderTypeAndSelfMention() async throws {
    let fixture = makeSearchFixture(suffix: "993")
    let otherChannel = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "search-other-993", creatorUserId: fixture.ownerId)
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: otherChannel, memberId: fixture.ownerId, name: "search-other-993")
    fixture.accounts.oauth.addChannelHuman(channelId: otherChannel, userId: fixture.ownerId)
    let agent = fixture.accounts.oauth.createAgent(serverId: fixture.serverId, name: "search-agent-993", runtime: "codex")
    let ownerMessage = fixture.accounts.addChannelMessageForTesting(channelId: fixture.channelId, content: "scope needle owner", senderId: fixture.ownerId)
    let agentMessage = fixture.accounts.addChannelMessageForTesting(channelId: fixture.channelId, content: "scope needle agent", senderId: agent, senderType: "agent")
    let otherMessage = fixture.accounts.addChannelMessageForTesting(channelId: otherChannel, content: "scope needle other", senderId: fixture.ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await searchLogin(client, email: fixture.ownerEmail)
            let headers = searchHeaders(token, fixture.serverId)
            func ids(_ path: String) async throws -> [String] {
                let response = try await client.get(URI(string: path), headers: headers)
                #expect(response.status == .ok)
                return try searchResults(response).compactMap { $0["id"] as? String }
            }
            #expect(try await ids("/api/messages/search?channelId=\(fixture.channelId)") == [agentMessage, ownerMessage])
            #expect(try await ids("/api/messages/search?senderType=agent") == [agentMessage])
            #expect(Set(try await ids("/api/messages/search?senderId=\(fixture.ownerId)")) == Set([otherMessage, ownerMessage]))

            let mentioned = try await client.send(.post, headers: {
                var headers = headers
                headers[.contentType] = "application/json"
                return headers
            }(), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"self mention target @search-owner-993\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(fixture.ownerId)\",\"name\":\"search-owner-993\"}]}")
            }
            #expect(mentioned.status == .ok)
            let mentionId = try #require((try searchBody(mentioned))["id"] as? String)
            #expect(try await ids("/api/messages/search?mentionTarget=self") == [mentionId])
        }
    }
}

@Test func messageSearchCloaksPrivateAndDropsDeletedButKeepsArchived() async throws {
    let fixture = makeSearchFixture(suffix: "994")
    let outsiderId = "11111111-1111-4111-8111-000000981994"
    let outsiderEmail = "search-outsider-994@slock.test"
    fixture.accounts.addAccount(id: outsiderId, email: outsiderEmail, password: "password123")
    fixture.accounts.markEmailVerified(userId: outsiderId)
    fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: outsiderId, role: "member")
    let privateChannel = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "search-private-994", creatorUserId: fixture.ownerId, type: "private")
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: privateChannel, memberId: fixture.ownerId, kind: "private", name: "search-private-994")
    let privateMessage = fixture.accounts.addChannelMessageForTesting(channelId: privateChannel, content: "cloak needle private", senderId: fixture.ownerId)
    let archivedChannel = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "search-archived-994", creatorUserId: fixture.ownerId)
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: archivedChannel, memberId: outsiderId, name: "search-archived-994")
    let archivedMessage = fixture.accounts.addChannelMessageForTesting(channelId: archivedChannel, content: "cloak needle archived", senderId: fixture.ownerId)
    let deletedChannel = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "search-deleted-994", creatorUserId: fixture.ownerId)
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: deletedChannel, memberId: outsiderId, name: "search-deleted-994")
    let deletedMessage = fixture.accounts.addChannelMessageForTesting(channelId: deletedChannel, content: "cloak needle deleted", senderId: fixture.ownerId)
    fixture.accounts.archiveChannel(channelId: archivedChannel)
    fixture.accounts.markChannelDeleted(channelId: deletedChannel)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let outsider = try await searchLogin(client, email: outsiderEmail)
            let response = try await client.get(
                URI(string: "/api/messages/search?q=cloak%20needle&limit=100"),
                headers: searchHeaders(outsider, fixture.serverId)
            )
            #expect(response.status == .ok)
            let ids = try searchResults(response).compactMap { $0["id"] as? String }
            #expect(!ids.contains(privateMessage))
            #expect(!ids.contains(deletedMessage))
            #expect(ids.contains(archivedMessage))

            let privateFilter = try await client.get(
                URI(string: "/api/messages/search?channelId=\(privateChannel)"),
                headers: searchHeaders(outsider, fixture.serverId)
            )
            #expect(privateFilter.status == .notFound)
        }
    }
}
