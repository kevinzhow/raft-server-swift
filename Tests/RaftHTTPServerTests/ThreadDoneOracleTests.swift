import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct DoneOracleFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let otherServerId: String
    let ownerId: String
    let ownerEmail: String
    let publicChannel: String
    let thread: String
    let hiddenThread: String
    let hiddenChannel: String
    let otherThread: String
}

private func makeDoneOracleFixture() -> DoneOracleFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001010001"
    let otherServerId = "33333333-3333-4333-8333-000001010002"
    let ownerId = "11111111-1111-4111-8111-000001010001"
    let memberId = "11111111-1111-4111-8111-000001010002"
    let ownerEmail = "done-oracle-owner@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, "done-oracle-member@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "done-oracle", name: "Done Oracle", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "done-oracle-other", name: "Done Oracle Other", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "done-oracle-public", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannel, memberId: ownerId, name: "done-oracle-public")
    accounts.oauth.addChannelHuman(channelId: publicChannel, userId: ownerId)
    let parent = accounts.addChannelMessageForTesting(channelId: publicChannel, content: "parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: publicChannel, parentMessageId: parent)
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: publicChannel, parentMessageId: parent, name: "thread")

    let hiddenChannel = accounts.oauth.createChannel(serverId: serverId, name: "done-oracle-private", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: hiddenChannel, memberId: memberId, kind: "private", name: "done-oracle-private")
    accounts.oauth.addChannelHuman(channelId: hiddenChannel, userId: memberId)
    let hiddenParent = accounts.addChannelMessageForTesting(channelId: hiddenChannel, content: "hidden", senderId: memberId)
    let hiddenThread = accounts.oauth.createThreadChannel(parentChannelId: hiddenChannel, parentMessageId: hiddenParent)
    accounts.addPostableChannel(serverId: serverId, channelId: hiddenThread, memberId: memberId, kind: "thread", parentChannelId: hiddenChannel, parentMessageId: hiddenParent, name: "thread")

    let otherChannel = accounts.oauth.createChannel(serverId: otherServerId, name: "done-oracle-elsewhere", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: otherServerId, channelId: otherChannel, memberId: ownerId, name: "done-oracle-elsewhere")
    accounts.oauth.addChannelHuman(channelId: otherChannel, userId: ownerId)
    let otherParent = accounts.addChannelMessageForTesting(channelId: otherChannel, content: "elsewhere", senderId: ownerId)
    let otherThread = accounts.oauth.createThreadChannel(parentChannelId: otherChannel, parentMessageId: otherParent)
    accounts.addPostableChannel(serverId: otherServerId, channelId: otherThread, memberId: ownerId, kind: "thread", parentChannelId: otherChannel, parentMessageId: otherParent, name: "thread")

    return DoneOracleFixture(
        accounts: accounts,
        serverId: serverId,
        otherServerId: otherServerId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        publicChannel: publicChannel,
        thread: thread,
        hiddenThread: hiddenThread,
        hiddenChannel: hiddenChannel,
        otherThread: otherThread
    )
}

private func doneOracleLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

@Test func threadDoneKeepsDeniedCausesByteIdenticalAndRejectsWrongTypeOnlyWhenVisible() async throws {
    let fixture = makeDoneOracleFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await doneOracleLogin(client, email: fixture.ownerEmail)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(owner)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            func done(_ id: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/channels/threads/done") { request in
                    request.body = .init(string: "{\"threadChannelId\":\"\(id)\",\"throughActivitySeq\":\"1\",\"frontierSpace\":\"storage\"}")
                }
            }

            let absent = try await done("99999999-9999-4999-8999-999999999999")
            let hiddenThread = try await done(fixture.hiddenThread)
            let hiddenWrongType = try await done(fixture.hiddenChannel)
            #expect(absent.status == .notFound)
            #expect(hiddenThread.status == .notFound)
            #expect(hiddenWrongType.status == .notFound)
            let absentBody = (absent.body.string ?? "")
            #expect((hiddenThread.body.string ?? "") == absentBody)
            #expect((hiddenWrongType.body.string ?? "") == absentBody)

            let malformed = try await done("not-a-uuid")
            let crossServer = try await done(fixture.otherThread)
            #expect(malformed.status == .notFound)
            #expect(crossServer.status == .notFound)
            #expect((malformed.body.string ?? "") == absentBody)
            #expect((crossServer.body.string ?? "") == absentBody)

            let wrongType = try await done(fixture.publicChannel)
            #expect(wrongType.status == .badRequest)
            #expect(((try JSONSerialization.jsonObject(with: Data((wrongType.body.string ?? "").utf8))) as? [String: Any])?["code"] as? String == "NOT_A_THREAD")

            let healthy = try await done(fixture.thread)
            #expect(healthy.status == .ok)

            fixture.accounts.oauth.setChannelReadCursor(channelId: fixture.thread, userId: fixture.ownerId, seq: 1)
            fixture.accounts.markChannelDeleted(channelId: fixture.thread)
            let deleted = try await done(fixture.thread)
            #expect(deleted.status == .ok)
        }
    }
}
