import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct StorageColumnsFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let email: String
    let channelId: String
}

private func makeStorageColumnsFixture(suffix: String) -> StorageColumnsFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-33333355\(suffix)"
    let ownerId = "11111111-1111-4111-8111-11111155\(suffix)"
    let email = "storage-cols-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: email, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "storage-cols-\(suffix)", name: "Storage Cols \(suffix)", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "storage-cols-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "storage-cols-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    return StorageColumnsFixture(accounts: accounts, serverId: serverId, ownerId: ownerId, email: email, channelId: channel)
}

private func storageColumnsLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func storageHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

@Test func messageHistoryReadsNeverSerializeStorageOnlyColumns() async throws {
    let fixture = makeStorageColumnsFixture(suffix: "901")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await storageColumnsLogin(client, email: fixture.email)
            let headers = storageHeaders(token, fixture.serverId)
            func send(_ content: String, path: String = "/api/messages") async throws -> [String: Any] {
                let response = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"\(content)\"}")
                }
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let first = try await send("searchable words for the index")
            _ = try await send("another searchable message")
            let firstId = first["id"] as? String ?? ""

            func rows(_ path: String) async throws -> [[String: Any]] {
                let response = try await client.get(URI(string: path), headers: headers)
                #expect(response.status == .ok, "\(path)")
                let object = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))
                if let array = object as? [[String: Any]] { return array }
                if let dictionary = object as? [String: Any], let array = dictionary["messages"] as? [[String: Any]] {
                    return array
                }
                return []
            }

            let page = try await rows("/api/messages/channel/\(fixture.channelId)?limit=50")
            #expect(page.count == 2)
            let context = try await rows("/api/messages/context/\(firstId)?channelId=\(fixture.channelId)")
            #expect(!context.isEmpty)
            let sync = try await rows("/api/messages/sync?since_seq=0&channel_id=\(fixture.channelId)")
            #expect(!sync.isEmpty)
            for (surface, list) in [("channel page", page), ("message context", context), ("message sync", sync)] {
                for row in list {
                    #expect(row["searchText"] == nil, "\(surface)")
                    #expect(row["searchVector"] == nil, "\(surface)")
                }
            }
        }
    }
}

@Test func messageSendsStoreOnlyValidSenderTimezonesAndNeverEchoThem() async throws {
    let fixture = makeStorageColumnsFixture(suffix: "902")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await storageColumnsLogin(client, email: fixture.email)
            let headers = storageHeaders(token, fixture.serverId)

            func send(path: String, content: String, timezone: String?, omit: Bool = false) async throws -> (id: String, echoed: Bool) {
                var body = "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"\(content)\""
                if !omit, let timezone {
                    body += ",\"timezone\":\(timezone)"
                }
                body += "}"
                let response = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
                #expect(response.status == .ok, "\(content)")
                let object = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                let message = path == "/api/v2/messages" ? (object["message"] as? [String: Any] ?? [:]) : object
                return (message["id"] as? String ?? "", message["senderTimezone"] != nil)
            }

            let validV2 = try await send(path: "/api/v2/messages", content: "valid v2", timezone: "\"Asia/Shanghai\"")
            #expect(!validV2.echoed)
            #expect(fixture.accounts.storedSenderTimezone(messageId: validV2.id) == "Asia/Shanghai")
            let validV1 = try await send(path: "/api/messages", content: "valid v1", timezone: "\" Europe/Berlin \"")
            #expect(fixture.accounts.storedSenderTimezone(messageId: validV1.id) == "Europe/Berlin")
            let utc = try await send(path: "/api/v2/messages", content: "utc", timezone: "\"UTC\"")
            #expect(fixture.accounts.storedSenderTimezone(messageId: utc.id) == "UTC")
            for (content, timezone) in [
                ("unknown zone", "\"Mars/Olympus_Mons\""),
                ("abbreviation", "\"EST\""),
                ("offset", "\"+05:00\""),
                ("overlong", "\"Asia/\(String(repeating: "x", count: 200))\""),
                ("non-string", "480"),
                ("null", "null"),
            ] {
                let sent = try await send(path: "/api/v2/messages", content: content, timezone: timezone)
                #expect(!sent.echoed, "\(content)")
                #expect(fixture.accounts.storedSenderTimezone(messageId: sent.id) == nil, "\(content)")
            }
            let omitted = try await send(path: "/api/v2/messages", content: "omitted", timezone: nil, omit: true)
            #expect(!omitted.echoed)
            #expect(fixture.accounts.storedSenderTimezone(messageId: omitted.id) == nil)

            let page = try await client.get(URI(string: "/api/messages/channel/\(fixture.channelId)?limit=50"), headers: headers)
            let pageBody = try JSONSerialization.jsonObject(with: Data((page.body.string ?? "").utf8)) as? [String: Any]
            let pageRows = pageBody?["messages"] as? [[String: Any]] ?? []
            #expect(!pageRows.isEmpty)
            let zoned = pageRows.first { $0["content"] as? String == "valid v2" }
            #expect(zoned != nil)
            let context = try await client.get(URI(string: "/api/messages/context/\(validV2.id)?channelId=\(fixture.channelId)"), headers: headers)
            let contextBody = try JSONSerialization.jsonObject(with: Data((context.body.string ?? "").utf8)) as? [String: Any]
            let contextRows = contextBody?["messages"] as? [[String: Any]] ?? []
            #expect(!contextRows.isEmpty)
            let sync = try await client.get(URI(string: "/api/messages/sync?since_seq=0&channel_id=\(fixture.channelId)"), headers: headers)
            let syncRows = try JSONSerialization.jsonObject(with: Data((sync.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(!syncRows.isEmpty)
            for (surface, list) in [("channel page", pageRows), ("message context", contextRows), ("message sync", syncRows)] {
                for row in list {
                    #expect(row["senderTimezone"] == nil, "\(surface)")
                }
            }
        }
    }
}
