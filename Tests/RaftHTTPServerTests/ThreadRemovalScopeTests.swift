import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func removalLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func removalHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

@Test func publicParentMemberRemovalPreservesThreadFollowsButServerRemovalPrunesPrivateOnes() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000997001"
    let ownerId = "11111111-1111-4111-8111-000000997001"
    let memberId = "11111111-1111-4111-8111-000000997002"
    let ownerEmail = "removal-owner@slock.test"
    let memberEmail = "removal-member@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "removal", name: "Removal", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "removal-public", creatorUserId: ownerId)
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "removal-private", creatorUserId: ownerId, type: "private")
    for channel in [publicChannel, privateChannel] {
        for id in [ownerId, memberId] {
            accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, kind: channel == privateChannel ? "private" : "channel", name: "removal")
            accounts.oauth.addChannelHuman(channelId: channel, userId: id)
        }
    }
    let publicParent = accounts.addChannelMessageForTesting(channelId: publicChannel, content: "public parent", senderId: ownerId)
    let privateParent = accounts.addChannelMessageForTesting(channelId: privateChannel, content: "private parent", senderId: ownerId)
    let publicThread = accounts.oauth.createThreadChannel(parentChannelId: publicChannel, parentMessageId: publicParent)
    let privateThread = accounts.oauth.createThreadChannel(parentChannelId: privateChannel, parentMessageId: privateParent)
    for (thread, parent, channel) in [(publicThread, publicParent, publicChannel), (privateThread, privateParent, privateChannel)] {
        accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: channel, parentMessageId: parent, name: "thread")
        accounts.followThreadForTesting(serverId: serverId, userId: memberId, threadChannelId: thread, parentMessageId: parent)
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await removalLogin(client, email: ownerEmail)
            let headers = removalHeaders(owner, serverId)

            let publicRemoval = try await client.send(.delete, headers: headers, to: URI(string: "/api/channels/\(publicChannel)/members/user/\(memberId)"))
            #expect(publicRemoval.status == .ok)
            #expect(accounts.threadFollowerIdsForTesting(threadChannelId: publicThread).contains(memberId))

            let privateRemoval = try await client.send(.delete, headers: headers, to: URI(string: "/api/channels/\(privateChannel)/members/user/\(memberId)"))
            #expect(privateRemoval.status == .ok)
            #expect(accounts.threadFollowerIdsForTesting(threadChannelId: privateThread).contains(memberId))

            let serverRemoval = try await client.send(.delete, headers: headers, to: URI(string: "/api/servers/\(serverId)/members/\(memberId)"))
            #expect(serverRemoval.status == .ok)
            #expect(!accounts.threadFollowerIdsForTesting(threadChannelId: privateThread).contains(memberId))
            #expect(accounts.threadFollowerIdsForTesting(threadChannelId: publicThread).contains(memberId))
        }
    }
}
