import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func attachmentQueryTokenMintsAStreamingURLThatCarriesTheToken() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001018001"
    let ownerId = "11111111-1111-4111-8111-000001018001"
    let ownerEmail = "query-token-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "query-token", name: "Query Token", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "query-token-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "query-token-room")
    let attachment = accounts.addChannelAttachment(channelId: channel, uploaderId: ownerId, filename: "secret.txt", mimeType: "text/plain", sizeBytes: 12)

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
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""

            let hop1 = try await client.get(URI(string: "/api/attachments/\(attachment)/url?serverId=\(serverId)&token=\(token)"))
            #expect(hop1.status == .ok)
            let hopBody = (try JSONSerialization.jsonObject(with: Data((hop1.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(hopBody["expiresAt"] is NSNull)
            let streamURL = try #require(hopBody["url"] as? String)
            let components = URLComponents(string: streamURL)
            #expect(components?.queryItems?.first { $0.name == "token" }?.value == token)
            #expect(components?.queryItems?.first { $0.name == "serverId" }?.value == serverId)

            let hop2 = try await client.get(URI(string: streamURL))
            #expect(hop2.status == .notFound)
            #expect(hop2.status != .unauthorized)

            let invalid = try await client.get(URI(string: "/api/attachments/\(attachment)/url?serverId=\(serverId)&token=invalid"))
            #expect(invalid.status == .unauthorized)
        }
    }
}

@Test func attachmentReadAcceptsComputerCredentialForItsLinkedServer() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001018002"
    let otherServerId = "33333333-3333-4333-8333-000001018003"
    let ownerId = "11111111-1111-4111-8111-000001018001"
    accounts.addAccount(id: ownerId, email: "computer-attach-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "computer-attach", name: "Computer Attach", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "computer-attach-other", name: "Computer Other", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "computer-attach-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "computer-attach-room")
    let attachment = accounts.addChannelAttachment(channelId: channel, uploaderId: ownerId, filename: "computer-download.txt", mimeType: "text/plain", sizeBytes: 42)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "computer-attach-machine")
    accounts.linkComputerForTesting(serverId: serverId, machineId: machine, online: true)
    let key = try #require(accounts.computerAPIKeyForTesting(machineId: machine))

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            let response = try await client.get(URI(string: "/api/attachments/\(attachment)"), headers: headers)
            #expect(response.status == .ok)
            #expect(response.status != .unauthorized)
            #expect(response.status != .forbidden)

            var wrongHeaders = headers
            wrongHeaders[HTTPField.Name("X-Server-Id")!] = otherServerId
            #expect(try await client.get(URI(string: "/api/attachments/\(attachment)"), headers: wrongHeaders).status == .forbidden)
        }
    }
}
