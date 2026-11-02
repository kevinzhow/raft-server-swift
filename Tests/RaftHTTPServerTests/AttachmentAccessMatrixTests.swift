import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func attachmentSingleIdReadsCarryTheAccessMatrix() async throws {
    let accounts = EmailLoginDirectory()
    let serverA = "33333333-3333-4333-8333-000001015001"
    let serverB = "33333333-3333-4333-8333-000001015002"
    let ownerId = "11111111-1111-4111-8111-000001015001"
    let userBId = "11111111-1111-4111-8111-000001015002"
    let ownerEmail = "attach-matrix-owner@slock.test"
    let userBEmail = "attach-matrix-b@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (userBId, userBEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverA, slug: "attach-a", name: "Attach A", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: serverB, slug: "attach-b", name: "Attach B", ownerId: userBId)
    let channel = accounts.oauth.createChannel(serverId: serverA, name: "attach-a-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverA, channelId: channel, memberId: ownerId, name: "attach-a-room")
    let attachment = accounts.addChannelAttachment(channelId: channel, uploaderId: ownerId, filename: "doc.txt")

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
            let owner = try await login(ownerEmail)
            let userB = try await login(userBEmail)
            func headers(_ token: String, _ server: String?) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                if let server { fields[HTTPField.Name("X-Server-Id")!] = server }
                return fields
            }
            func get(_ path: String, _ fields: HTTPFields) async throws -> ClientResponse {
                try await client.get(URI(string: path), headers: fields)
            }
            func body(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }

            #expect(try await get("/api/attachments/\(attachment)", headers(owner, nil)).status == .badRequest)
            #expect(try await get("/api/attachments/\(attachment)", headers(userB, serverA)).status == .forbidden)
            let cross = try await get("/api/attachments/\(attachment)", headers(userB, serverB))
            #expect(cross.status == .notFound)
            #expect(body(cross) as NSDictionary == ["error": "Attachment not found"] as NSDictionary)

            for malformed in ["not-a-uuid", "00000000-0000-4000-8000-00000000000"] {
                for suffix in ["", "/url", "/html-preview-url"] {
                    let response = try await get("/api/attachments/\(malformed)\(suffix)", headers(owner, serverA))
                    #expect(response.status == .badRequest, "\(suffix) must be typed 400")
                    #expect(body(response)["code"] as? String == "invalid_attachment_id")
                }
            }
            let absent = try await get("/api/attachments/00000000-0000-4000-8000-0000000009ff", headers(owner, serverA))
            #expect(absent.status == .notFound)
            #expect(body(absent) as NSDictionary == ["error": "Attachment not found"] as NSDictionary)

            let own = try await get("/api/attachments/\(attachment)", headers(owner, serverA))
            #expect(own.status == .ok)
            #expect(body(own)["filename"] as? String == "doc.txt")
        }
    }
}
