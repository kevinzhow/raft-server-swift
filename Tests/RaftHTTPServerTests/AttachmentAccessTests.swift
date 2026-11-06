import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func channelFilesAndAttachmentReadsCloakPrivateChannels() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111489"
    let memberId = "11111111-1111-4111-8111-111111111490"
    let serverId = "33333333-3333-4333-8333-333333333589"
    accounts.addAccount(id: ownerId, email: "attachment-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "attachment-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "attachment-access", name: "Attachment Access", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "attachment-public", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannel, memberId: memberId, name: "attachment-public")
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "attachment-private", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: ownerId, name: "attachment-private")
    accounts.oauth.setChannelType(id: privateChannel, type: "private")
    accounts.setChannelPostablePrivateForTesting(channelId: privateChannel)
    let publicAttachment = UUID().uuidString.lowercased()
    let privateAttachment = UUID().uuidString.lowercased()
    accounts.addChannelAttachmentForTesting(channelId: publicChannel, id: publicAttachment, uploaderId: ownerId, filename: "public.txt")
    accounts.addChannelAttachmentForTesting(channelId: privateChannel, id: privateAttachment, uploaderId: ownerId, filename: "private.txt")

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
                request.body = .init(string: "{\"email\":\"attachment-member@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let publicFiles = try await client.send(.get, headers: headers, to: "/api/channels/\(publicChannel)/files")
            #expect(publicFiles.status == .ok)
            #expect((publicFiles.body.string ?? "").contains("public.txt"))
            #expect(try await client.send(.get, headers: headers, to: "/api/channels/\(privateChannel)/files").status == .notFound)

            #expect(try await client.send(.get, headers: headers, to: "/api/attachments/\(publicAttachment)").status == .ok)
            #expect(try await client.send(.get, headers: headers, to: "/api/attachments/\(privateAttachment)").status == .notFound)
            #expect(try await client.send(.get, headers: headers, to: "/api/attachments/\(publicAttachment)/html-preview-url").status == .ok)
            #expect(try await client.send(.get, headers: headers, to: "/api/attachments/\(privateAttachment)/html-preview-url").status == .notFound)
        }
    }
}
