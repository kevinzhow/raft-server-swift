import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ChannelFilesFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let channelId: String
}

private func makeChannelFilesFixture(suffix: String) -> ChannelFilesFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-33333344\(suffix)"
    let ownerId = "11111111-1111-4111-8111-11111144\(suffix)"
    let ownerEmail = "files-owner-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "files-\(suffix)", name: "Files \(suffix)", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "files-room-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "files-room-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    return ChannelFilesFixture(accounts: accounts, serverId: serverId, ownerId: ownerId, ownerEmail: ownerEmail, channelId: channel)
}

private func channelFilesLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func sendMessage(_ client: any Client, token: String, serverId: String, channelId: String, content: String) async throws -> String {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    let response = try await client.send(.post, headers: headers, to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
}

@Test func channelFilesListDirectAndThreadAttachmentsWithJumpMetadata() async throws {
    let fixture = makeChannelFilesFixture(suffix: "801")
    let accounts = fixture.accounts
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await channelFilesLogin(client, email: fixture.ownerEmail)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId

            let directMessage = try await sendMessage(client, token: token, serverId: fixture.serverId, channelId: fixture.channelId, content: "direct attachment")
            let parentMessage = try await sendMessage(client, token: token, serverId: fixture.serverId, channelId: fixture.channelId, content: "thread parent")
            var createHeaders = headers
            createHeaders[.contentType] = "application/json"
            let threadResponse = try await client.send(.post, headers: createHeaders, to: "/api/channels/\(fixture.channelId)/threads") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(parentMessage)\"}")
            }
            let threadId = (try JSONSerialization.jsonObject(with: Data((threadResponse.body.string ?? "").utf8)) as? [String: Any])?["threadChannelId"] as? String ?? ""
            let threadMessage = try await sendMessage(client, token: token, serverId: fixture.serverId, channelId: threadId, content: "thread attachment")

            accounts.addChannelFileForTesting(
                channelId: fixture.channelId,
                id: "00000000-0000-4000-8000-000000000101",
                uploaderId: fixture.ownerId,
                messageId: directMessage,
                filename: "direct.pdf",
                mimeType: "application/pdf",
                sizeBytes: 1234,
                createdAt: iso.date(from: "2026-05-10T10:00:00.000Z")!
            )
            accounts.addChannelFileForTesting(
                channelId: threadId,
                id: "00000000-0000-4000-8000-000000000102",
                uploaderId: fixture.ownerId,
                messageId: threadMessage,
                filename: "thread.png",
                mimeType: "image/png",
                sizeBytes: 5678,
                createdAt: iso.date(from: "2026-05-10T11:00:00.000Z")!
            )

            let response = try await client.get(URI(string: "/api/channels/\(fixture.channelId)/files"), headers: headers)
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let files = body?["files"] as? [[String: Any]] ?? []
            #expect(body?["nextCursor"] is NSNull)
            #expect(files.map { $0["filename"] as? String } == ["thread.png", "direct.pdf"])
            #expect(files.allSatisfy { $0["sizeBytes"] is Int })
            #expect(files.allSatisfy { $0["mimeType"] is String })

            let threadFile = files[0]
            #expect(threadFile["messageId"] as? String == threadMessage)
            let threadSource = threadFile["source"] as? [String: Any]
            #expect(threadSource?["type"] as? String == "thread")
            #expect(threadSource?["channelId"] as? String == threadId)
            #expect(threadSource?["parentMessageId"] as? String == parentMessage)
            #expect(threadSource?["parentMessageShortId"] as? String == String(parentMessage.prefix(8)))
            let threadUploader = threadFile["uploader"] as? [String: Any]
            #expect(threadUploader?["name"] as? String == "files-owner-801")
            #expect(threadUploader?["displayName"] as? String == "files-owner-801")

            let directFile = files[1]
            #expect(directFile["messageId"] as? String == directMessage)
            let directSource = directFile["source"] as? [String: Any]
            #expect(directSource?["type"] as? String == "channel")
            #expect(directSource?["channelId"] as? String == fixture.channelId)
            #expect(directSource?["parentMessageId"] is NSNull)

            let firstPage = try await client.get(URI(string: "/api/channels/\(fixture.channelId)/files?limit=1"), headers: headers)
            let firstBody = try JSONSerialization.jsonObject(with: Data((firstPage.body.string ?? "").utf8)) as? [String: Any]
            let firstFiles = firstBody?["files"] as? [[String: Any]] ?? []
            #expect(firstFiles.map { $0["filename"] as? String } == ["thread.png"])
            let cursor = firstBody?["nextCursor"] as? String
            #expect(cursor != nil)

            let secondPage = try await client.get(URI(string: "/api/channels/\(fixture.channelId)/files?limit=1&cursor=\(cursor ?? "")"), headers: headers)
            #expect(secondPage.status == .ok)
            let secondBody = try JSONSerialization.jsonObject(with: Data((secondPage.body.string ?? "").utf8)) as? [String: Any]
            let secondFiles = secondBody?["files"] as? [[String: Any]] ?? []
            #expect(secondFiles.map { $0["filename"] as? String } == ["direct.pdf"])
            #expect(secondBody?["nextCursor"] is NSNull)

            let invalidCursor = try await client.get(URI(string: "/api/channels/\(fixture.channelId)/files?cursor=not-a-cursor"), headers: headers)
            #expect(invalidCursor.status == .badRequest)
            #expect(((try? JSONSerialization.jsonObject(with: Data((invalidCursor.body.string ?? "").utf8))) as? [String: Any])?["error"] as? String == "Invalid cursor")
        }
    }
}

@Test func channelFilesRejectPrivateChannelNonMembers() async throws {
    let fixture = makeChannelFilesFixture(suffix: "802")
    let accounts = fixture.accounts
    let outsiderId = "11111111-1111-4111-8111-11111155802"
    let outsiderEmail = "files-private-outsider-802@slock.test"
    accounts.addAccount(id: outsiderId, email: outsiderEmail, password: "password123")
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addMember(serverId: fixture.serverId, userId: outsiderId, role: "member")
    let privateChannel = accounts.oauth.createChannel(serverId: fixture.serverId, name: "secret-files-802", creatorUserId: fixture.ownerId, type: "private")
    accounts.addPostableChannel(serverId: fixture.serverId, channelId: privateChannel, memberId: fixture.ownerId, kind: "private", name: "secret-files-802")
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: fixture.ownerId)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerToken = try await channelFilesLogin(client, email: fixture.ownerEmail)
            let message = try await sendMessage(client, token: ownerToken, serverId: fixture.serverId, channelId: privateChannel, content: "private attachment")
            accounts.addChannelFileForTesting(
                channelId: privateChannel,
                id: "00000000-0000-4000-8000-000000000201",
                uploaderId: fixture.ownerId,
                messageId: message,
                filename: "secret.txt",
                mimeType: "text/plain",
                sizeBytes: 10,
                createdAt: iso.date(from: "2026-05-10T10:00:00.000Z")!
            )

            var ownerHeaders = HTTPFields()
            ownerHeaders[.authorization] = "Bearer \(ownerToken)"
            ownerHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let ownerResponse = try await client.get(URI(string: "/api/channels/\(privateChannel)/files"), headers: ownerHeaders)
            #expect(ownerResponse.status == .ok)

            let outsiderToken = try await channelFilesLogin(client, email: outsiderEmail)
            var outsiderHeaders = HTTPFields()
            outsiderHeaders[.authorization] = "Bearer \(outsiderToken)"
            outsiderHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let outsiderResponse = try await client.get(URI(string: "/api/channels/\(privateChannel)/files"), headers: outsiderHeaders)
            #expect(outsiderResponse.status == .notFound)
            #expect(((try? JSONSerialization.jsonObject(with: Data((outsiderResponse.body.string ?? "").utf8))) as? [String: Any])?["error"] as? String == "Channel not found")
        }
    }
}

@Test func channelFilesResolveUserAgentAndLegacyUploaders() async throws {
    let fixture = makeChannelFilesFixture(suffix: "803")
    let accounts = fixture.accounts
    let agentId = accounts.oauth.createAgent(serverId: fixture.serverId, name: "files-uploaders-agent")
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await channelFilesLogin(client, email: fixture.ownerEmail)
            let message = try await sendMessage(client, token: token, serverId: fixture.serverId, channelId: fixture.channelId, content: "three uploads")
            for (index, entry) in [
                ("00000000-0000-4000-8000-000000000301", fixture.ownerId, "user", "by-user.pdf"),
                ("00000000-0000-4000-8000-000000000302", agentId, "agent", "by-agent.pdf"),
                ("00000000-0000-4000-8000-000000000303", "legacy-uploader", "user", "by-legacy.pdf"),
            ].enumerated() {
                accounts.addChannelFileForTesting(
                    channelId: fixture.channelId,
                    id: entry.0,
                    uploaderId: entry.1,
                    uploaderType: entry.2,
                    messageId: message,
                    filename: entry.3,
                    mimeType: "application/pdf",
                    sizeBytes: 1,
                    createdAt: iso.date(from: "2026-05-10T10:0\(index):00.000Z")!
                )
            }

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let response = try await client.get(URI(string: "/api/channels/\(fixture.channelId)/files"), headers: headers)
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let files = body?["files"] as? [[String: Any]] ?? []
            #expect(files.map { $0["filename"] as? String } == ["by-legacy.pdf", "by-agent.pdf", "by-user.pdf"])
            let byName = Dictionary(uniqueKeysWithValues: files.map { ($0["filename"] as? String ?? "", $0) })
            #expect((byName["by-user.pdf"]?["uploader"] as? [String: Any])?["name"] as? String == "files-owner-803")
            #expect((byName["by-agent.pdf"]?["uploader"] as? [String: Any])?["name"] as? String == "files-uploaders-agent")
            #expect((byName["by-legacy.pdf"]?["uploader"] as? [String: Any])?["id"] as? String == "legacy-uploader")
            #expect((byName["by-legacy.pdf"]?["uploader"] as? [String: Any])?["name"] is NSNull)
        }
    }
}
