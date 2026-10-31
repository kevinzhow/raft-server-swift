import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadInfoIsScopedToTheRequestedChannel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111540"
    let outsiderId = "11111111-1111-4111-8111-111111111541"
    let serverId = "33333333-3333-4333-8333-333333333617"
    accounts.addAccount(id: ownerId, email: "thread-info-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: outsiderId, email: "thread-info-outside@slock.test", password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-info", name: "Thread Info", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "thread-info-public", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannel, memberId: outsiderId, name: "thread-info-public")
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "thread-info-private", creatorUserId: ownerId, type: "private")
    accounts.oauth.setChannelType(id: privateChannel, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: ownerId, kind: "private", name: "thread-info-private")
    let privateParent = accounts.oauth.createMessageRecord(channelId: privateChannel, content: "private parent", senderId: ownerId)
    let privateThread = accounts.oauth.createThreadChannel(parentChannelId: privateChannel, parentMessageId: privateParent.id)
    accounts.addPostableChannel(serverId: serverId, channelId: privateThread, memberId: ownerId, kind: "thread", parentChannelId: privateChannel, parentMessageId: privateParent.id, name: "thread")
    let publicParent = accounts.oauth.createMessageRecord(channelId: publicChannel, content: "public parent", senderId: outsiderId)
    let publicThread = accounts.oauth.createThreadChannel(parentChannelId: publicChannel, parentMessageId: publicParent.id)
    accounts.addPostableChannel(serverId: serverId, channelId: publicThread, memberId: ownerId, kind: "thread", parentChannelId: publicChannel, parentMessageId: publicParent.id, name: "thread")

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
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("thread-info-owner@slock.test")
            let outsiderToken = try await login("thread-info-outside@slock.test")
            var ownerSendHeaders = headers(ownerToken)
            ownerSendHeaders[.contentType] = "application/json"
            let privateReply = try await client.send(.post, headers: ownerSendHeaders, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(privateThread)\",\"content\":\"private reply\"}")
            }
            #expect(privateReply.status == .ok)
            let outsiderViaPublic = try await client.send(.get, headers: headers(outsiderToken), to: "/api/channels/\(publicChannel)/threads/\(privateParent.id)")
            #expect(outsiderViaPublic.status == .notFound)
            let wrongChannel = try await client.send(.get, headers: headers(ownerToken), to: "/api/channels/\(privateChannel)/threads/\(publicParent.id)")
            #expect(wrongChannel.status == .notFound)
            let privateInfo = try await client.send(.get, headers: headers(ownerToken), to: "/api/channels/\(privateChannel)/threads/\(privateParent.id)")
            #expect(privateInfo.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((privateInfo.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["threadChannelId"] as? String == privateThread)
            #expect(body?["replyCount"] as? Int == 1)
        }
    }
}
