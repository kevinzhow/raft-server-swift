import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadSummariesScopeToRequestedParentMessages() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111559"
    let serverId = "33333333-3333-4333-8333-333333333626"
    accounts.addAccount(id: ownerId, email: "scope-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "scope", name: "Scope", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "scope-channel", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "scope-channel")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"scope-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            var parents: [String] = []
            for index in 0..<3 {
                let message = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"parent \(index)\"}")
                }
                let id = (try JSONSerialization.jsonObject(with: Data((message.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
                parents.append(id)
                #expect(try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/threads") { request in
                    request.body = .init(string: "{\"parentMessageId\":\"\(id)\"}")
                }.status == .ok)
            }
            let all = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)/threads")
            #expect(((try JSONSerialization.jsonObject(with: Data((all.body.string ?? "").utf8)) as? [String: Any]) ?? [:]).count == 3)

            let scoped = try await client.send(.get, headers: headers, to: URI(string: "/api/channels/\(channel)/threads?parentMessageIds=\(parents[0]),\(parents[2])"))
            #expect(scoped.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((scoped.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(Set(body.keys) == Set([parents[0], parents[2]]))
        }
    }
}
