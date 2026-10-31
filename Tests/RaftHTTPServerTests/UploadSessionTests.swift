import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func disabledUploadSessionsFailTyped() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111530"
    let serverId = "33333333-3333-4333-8333-333333333611"
    accounts.addAccount(id: ownerId, email: "upload-session-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "upload-session", name: "Upload Session", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "upload-room", creatorUserId: ownerId)

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
                request.body = .init(string: "{\"email\":\"upload-session-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let create = try await client.send(.post, headers: headers, to: "/api/attachments/upload-sessions") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\",\"filename\":\"a.txt\",\"sizeBytes\":10}")
            }
            #expect(create.status == .forbidden)
            let createBody = try JSONSerialization.jsonObject(with: Data((create.body.string ?? "").utf8)) as? [String: Any]
            #expect(createBody?["code"] as? String == "UPLOAD_FORBIDDEN")
            #expect(createBody?["message"] as? String == "The member cannot upload to this channel.")
            #expect(createBody?["retryable"] as? Bool == false)

            let missingId = UUID().uuidString.lowercased()
            for (method, path) in [
                (HTTPRequest.Method.get, "/api/attachments/upload-sessions/\(missingId)"),
                (.delete, "/api/attachments/upload-sessions/\(missingId)"),
                (.post, "/api/attachments/upload-sessions/\(missingId)/complete"),
            ] {
                let response = try await client.send(method, headers: headers, to: URI(string: path))
                #expect(response.status == .notFound)
                #expect((try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "UPLOAD_SESSION_NOT_FOUND")
            }
            let malformed = try await client.send(.get, headers: headers, to: "/api/attachments/upload-sessions/not-a-uuid")
            #expect(malformed.status == .notFound)
        }
    }
}
