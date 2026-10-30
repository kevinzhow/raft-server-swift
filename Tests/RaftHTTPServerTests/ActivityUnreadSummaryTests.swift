import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func unreadSummaryCarriesKnownZeroAndMemberOnlyEntries() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111319"
    let memberId = "11111111-1111-4111-8111-111111111320"
    let outsiderId = "11111111-1111-4111-8111-111111111321"
    let serverA = "33333333-3333-4333-8333-333333333488"
    let serverB = "33333333-3333-4333-8333-333333333489"
    let serverC = "33333333-3333-4333-8333-333333333490"
    for (id, email) in [
        (ownerId, "act-owner@slock.test"),
        (memberId, "act-member@slock.test"),
        (outsiderId, "act-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    for (serverId, slug, name) in [
        (serverA, "activity-a", "Activity A"),
        (serverB, "activity-b", "Activity B"),
        (serverC, "activity-c", "Activity C"),
    ] {
        accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: name, ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    }
    let joined = accounts.oauth.createChannel(serverId: serverA, name: "joined-room", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: joined, userId: memberId)
    accounts.oauth.createChannelMessage(channelId: joined, content: "unread one", senderId: ownerId)
    accounts.oauth.createChannelMessage(channelId: joined, content: "unread two", senderId: ownerId)
    let mentionOnly = accounts.oauth.createChannel(serverId: serverA, name: "mention-room", creatorUserId: ownerId)
    accounts.oauth.createChannelMessage(channelId: mentionOnly, content: "@act-member ping", senderId: ownerId)
    _ = accounts.oauth.createChannel(serverId: serverB, name: "quiet-room", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: accounts.oauth.allChannelId(serverId: serverA) ?? "", userId: memberId)

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
                return fields
            }
            func summary(_ token: String) async throws -> [[String: Any]] {
                let response = try await client.send(.get, headers: headers(token), to: "/api/servers/unread-summary")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            }

            let memberToken = try await login("act-member@slock.test")
            let outsiderToken = try await login("act-outsider@slock.test")
            let memberSummary = try await summary(memberToken)
            let entryA = memberSummary.first { $0["serverId"] as? String == serverA }
            let entryB = memberSummary.first { $0["serverId"] as? String == serverB }
            #expect(entryA?["activityUnreadCount"] as? Int == 2)
            #expect(entryB?["activityUnreadCount"] as? Int == 0)
            #expect(entryB?.keys.contains("activityUnreadCount") == true)
            #expect(entryA?["serverPushMuted"] as? Bool == false)
            #expect(Set(entryA?.keys.map { $0 } ?? []) == ["serverId", "unreadCount", "serverPushMuted", "activityUnreadCount"])

            accounts.oauth.setServerPushMuted(serverId: serverA, userId: memberId, muted: true)
            let mutedSummary = try await summary(memberToken)
            let mutedA = mutedSummary.first { $0["serverId"] as? String == serverA }
            #expect(mutedA?["serverPushMuted"] as? Bool == true)
            #expect(mutedA?["activityUnreadCount"] as? Int == 2)

            let outsiderSummary = try await summary(outsiderToken)
            #expect(outsiderSummary.isEmpty)
        }
    }
}
