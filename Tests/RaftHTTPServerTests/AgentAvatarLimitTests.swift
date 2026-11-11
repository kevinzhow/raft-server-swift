import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private let avatarLimitGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!

private func avatarLimitMultipart(bytes: Data, mimeType: String) -> (contentType: String, body: Data) {
    let boundary = "avatar-boundary"
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.gif\"\r\n".utf8))
    body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
    body.append(bytes)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return ("multipart/form-data; boundary=\(boundary)", body)
}

@Test func oversizedAgentAvatarIsRejectedWithTheProfileLimit() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111275"
    let serverId = "33333333-3333-4333-8333-333333333462"
    accounts.addAccount(id: ownerId, email: "avatar-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "avatar-large", name: "Avatar Large", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "avatar-agent", creatorUserId: ownerId)

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
                request.body = .init(string: "{\"email\":\"avatar-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            let oversizedForm = avatarLimitMultipart(
                bytes: Data(repeating: 0, count: 5 * 1024 * 1024 + 1), mimeType: "image/png"
            )
            headers[.contentType] = oversizedForm.contentType

            let response = try await client.send(.post, headers: headers, to: "/api/agents/\(agentId)/avatar") { request in
                request.body = .init(data: oversizedForm.body)
            }
            #expect(response.status == .badRequest)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["error"] as? String == "Avatar image must be 5 MB or smaller")
            #expect(body?["errorCode"] as? String == "PROFILE_AVATAR_TOO_LARGE")
            #expect(body?["maxBytes"] as? Int == 5 * 1024 * 1024)

            headers[.contentType] = "application/json"
            let pixel = try await client.send(.patch, headers: headers, to: "/api/agents/\(agentId)") { request in
                request.body = .init(string: "{\"avatarUrl\":\"pixel:mug\"}")
            }
            #expect(pixel.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((pixel.body.string ?? "").utf8)) as? [String: Any])?["avatarUrl"] as? String == "pixel:mug")

            let smallForm = avatarLimitMultipart(bytes: avatarLimitGIF, mimeType: "image/gif")
            headers[.contentType] = smallForm.contentType
            let small = try await client.send(.post, headers: headers, to: "/api/agents/\(agentId)/avatar") { request in
                request.body = .init(data: smallForm.body)
            }
            #expect(small.status == .ok)
            let smallBody = try JSONSerialization.jsonObject(with: Data((small.body.string ?? "").utf8)) as? [String: Any]
            #expect((smallBody?["avatarUrl"] as? String)?.hasSuffix(".webp") == true)
            #expect((smallBody?["avatarUrl"] as? String)?.hasPrefix("/api/avatars/\(serverId)/") == true)
        }
    }
}
