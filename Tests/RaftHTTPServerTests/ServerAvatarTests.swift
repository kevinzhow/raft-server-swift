import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverAvatarUploadIsOwnerAndAdminOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111346"
    let adminId = "11111111-1111-4111-8111-111111111347"
    let memberId = "11111111-1111-4111-8111-111111111348"
    let serverId = "33333333-3333-4333-8333-333333333504"
    for (id, email) in [
        (ownerId, "server-avatar-owner@slock.test"),
        (adminId, "server-avatar-admin@slock.test"),
        (memberId, "server-avatar-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "server-avatar", name: "Server Avatar", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00])

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "multipart/form-data; boundary=avatar"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func upload(_ token: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: "/api/servers/\(serverId)/avatar") { request in
                    request.body = .init(data: gif)
                }
            }
            let ownerToken = try await login("server-avatar-owner@slock.test")
            let adminToken = try await login("server-avatar-admin@slock.test")
            let memberToken = try await login("server-avatar-member@slock.test")

            let ownerUpload = try await upload(ownerToken)
            #expect(ownerUpload.status == .ok)
            let ownerBody = try JSONSerialization.jsonObject(with: Data((ownerUpload.body.string ?? "").utf8)) as? [String: Any]
            let avatarUrl = ownerBody?["avatarUrl"] as? String ?? ""
            #expect(avatarUrl.wholeMatch(of: /^\/api\/avatars\/server-[0-9a-f-]+\/[0-9a-f]+\.webp$/) != nil)

            var detailHeaders = HTTPFields()
            detailHeaders[.authorization] = "Bearer \(ownerToken)"
            detailHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let detail = try await client.send(.get, headers: detailHeaders, to: "/api/servers/\(serverId)")
            #expect(detail.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((detail.body.string ?? "").utf8)) as? [String: Any])?["avatarUrl"] as? String == avatarUrl)

            #expect(try await upload(adminToken).status == .ok)
            #expect(try await upload(memberToken).status == .forbidden)
        }
    }
}
