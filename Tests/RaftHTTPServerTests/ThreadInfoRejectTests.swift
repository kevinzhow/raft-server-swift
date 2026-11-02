import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadInfo404BranchesCarryTheirPublishedBodies() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000999001"
    let otherServerId = "33333333-3333-4333-8333-000000999002"
    let ownerId = "11111111-1111-4111-8111-000000999001"
    let outsiderId = "11111111-1111-4111-8111-000000999002"
    let ownerEmail = "thread-info-owner@slock.test"
    let outsiderEmail = "thread-info-outsider@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (outsiderId, outsiderEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-info", name: "Thread Info", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "thread-info-other", name: "Thread Info Other", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "thread-info-public", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannel, memberId: ownerId, name: "thread-info-public")
    accounts.oauth.addChannelHuman(channelId: publicChannel, userId: ownerId)
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "thread-info-private", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: ownerId, kind: "private", name: "thread-info-private")
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: ownerId)
    let threadedParent = accounts.addChannelMessageForTesting(channelId: publicChannel, content: "threaded parent", senderId: ownerId)
    let bareParent = accounts.addChannelMessageForTesting(channelId: publicChannel, content: "no thread yet", senderId: ownerId)
    let privateParent = accounts.addChannelMessageForTesting(channelId: privateChannel, content: "private parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: publicChannel, parentMessageId: threadedParent)
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: publicChannel, parentMessageId: threadedParent, name: "thread")
    _ = accounts.addChannelMessageForTesting(channelId: thread, content: "reply", senderId: ownerId)

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
            func get(_ token: String, _ server: String, _ channel: String, _ message: String) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = server
                let response = try await client.get(URI(string: "/api/channels/\(channel)/threads/\(message)"), headers: headers)
                let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                return (response.status, body)
            }
            let owner = try await login(ownerEmail)
            let outsider = try await login(outsiderEmail)

            let found = try await get(owner, serverId, publicChannel, threadedParent)
            #expect(found.status == .ok)
            #expect(found.body["threadChannelId"] as? String == thread)

            let bare = try await get(owner, serverId, publicChannel, bareParent)
            #expect(bare.status == .notFound)
            #expect(bare.body as NSDictionary == ["code": "THREAD_NOT_FOUND", "error": "No thread found for this message"] as NSDictionary)

            let mismatch = try await get(owner, otherServerId, publicChannel, threadedParent)
            #expect(mismatch.status == .notFound)
            #expect(mismatch.body as NSDictionary == ["error": "Channel not found or not visible"] as NSDictionary)

            let denied = try await get(outsider, serverId, privateChannel, privateParent)
            #expect(denied.status == .notFound)
            #expect(denied.body as NSDictionary == ["error": "Channel not found or not visible"] as NSDictionary)

            let missing = try await get(owner, serverId, "99999999-9999-4999-8999-999999999999", threadedParent)
            #expect(missing.status == .notFound)
            #expect(missing.body as NSDictionary == ["error": "Channel not found or not visible"] as NSDictionary)
        }
    }
}
