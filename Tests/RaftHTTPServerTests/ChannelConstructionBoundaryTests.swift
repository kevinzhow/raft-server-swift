import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func constructedChannelRoutesObserveRoleChangesAndLiveSessionRevocation() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111646"
    let memberId = "11111111-1111-4111-8111-111111111647"
    let serverId = "33333333-3333-4333-8333-333333333671"
    for (id, email) in [(ownerId, "channel-construction-owner@slock.test"), (memberId, "channel-construction-member@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-construction", name: "Before Construction", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let parent = accounts.oauth.createChannel(serverId: serverId, name: "construction", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: memberId, name: "construction")
    accounts.oauth.addChannelHuman(channelId: parent, userId: memberId)
    let parentMessage = accounts.addChannelMessageForTesting(channelId: parent, content: "construction parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: parentMessage)
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: memberId, kind: "thread", parentChannelId: parent, parentMessageId: parentMessage, name: "construction thread")
    accounts.oauth.addChannelHuman(channelId: thread, userId: memberId)
    let ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
    let memberToken = accounts.mintAccessTokenForTesting(userId: memberId)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func fields(_ token: String) -> HTTPFields {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return headers
            }
            func rename() async throws -> ClientResponse {
                try await client.send(.patch, headers: fields(memberToken), to: "/api/servers/\(serverId)") { request in
                    request.body = .init(string: #"{"name":"After Construction"}"#)
                }
            }
            #expect(try await rename().status == .forbidden)
            let promoted = try await client.send(.patch, headers: fields(ownerToken), to: "/api/servers/\(serverId)/members/\(memberId)") { request in
                request.body = .init(string: #"{"role":"admin"}"#)
            }
            #expect(promoted.status == .ok)
            let renamed = try await rename()
            #expect(renamed.status == .ok)
            #expect(renamed.body.string?.contains("After Construction") == true)
            let followed = try await client.send(.post, headers: fields(memberToken), to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}")
            }
            #expect(followed.status == .ok)
            let page = try await client.get("/api/channels/threads/followed", headers: fields(memberToken))
            #expect(page.status == .ok)
            #expect(page.body.string?.contains(thread) == true)

            accounts.revokeSessionFamilies(userId: memberId)
            #expect(try await rename().status == .unauthorized)
            let revokedThreads = try await client.get("/api/channels/threads/followed", headers: fields(memberToken))
            #expect(revokedThreads.status == .unauthorized)
            let revokedMembers = try await client.send(.patch, headers: fields(memberToken), to: "/api/servers/\(serverId)/members/\(ownerId)") { request in
                request.body = .init(string: #"{"role":"member"}"#)
            }
            #expect(revokedMembers.status == .unauthorized)
            #expect(revokedMembers.body.string == #"{"error":"Invalid or expired token","code":"auth_required"}"#)
            #expect(revokedMembers.headers[.cacheControl] == "no-store")
        }
    }
}
