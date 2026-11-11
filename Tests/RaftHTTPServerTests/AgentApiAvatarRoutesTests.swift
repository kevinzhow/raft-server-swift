import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The agent avatar routes:
/// `POST /internal/agent-api/profile/avatar`, `POST /internal/agent-api/server/avatar`
/// and the legacy `POST /internal/agent/:id/server/avatar`.
@Test func agentApiProfileAndServerAvatarRoutesLockTheContract() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001029001"
    let ownerId = "11111111-1111-4111-8111-000001029001"
    accounts.addAccount(id: ownerId, email: "agent-avatar-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-avatar", name: "Agent Avatar", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "AvatarBot", runtime: "codex")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send", "server"], name: "avatar")
    let readonlyKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "read")
    let machineKey = accounts.registerMachineForAgent(serverId: serverId, agentId: agent)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func object(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
            func avatarHeaders(_ token: String, contentType: String = "image/png") -> HTTPFields {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = contentType
                return headers
            }

            // Profile avatar: the response is the caller's own profile view.
            let profileForm = MultipartTestBody(
                filename: "avatar.png", mimeType: "image/png", bytes: png
            )
            let profile = try await client.send(
                .post, headers: avatarHeaders(key, contentType: profileForm.contentType),
                to: "/internal/agent-api/profile/avatar"
            ) { request in
                request.body = .init(data: profileForm.body)
            }
            #expect(profile.status == .ok)
            let profileBody = object(profile)
            #expect(profileBody["agentId"] as? String == agent)
            let avatarUrl = try #require(profileBody["avatarUrl"] as? String)
            #expect(avatarUrl.hasPrefix("/api/avatars/\(serverId)/"))
            #expect(avatarUrl.hasSuffix(".webp"))

            let badFormatForm = MultipartTestBody(
                filename: "avatar.txt", mimeType: "text/plain", bytes: Data("hello".utf8)
            )
            let badFormat = try await client.send(
                .post, headers: avatarHeaders(key, contentType: badFormatForm.contentType),
                to: "/internal/agent-api/profile/avatar"
            ) { request in
                request.body = .init(data: badFormatForm.body)
            }
            #expect(badFormat.status == .badRequest)
            #expect(object(badFormat)["errorCode"] as? String == "PROFILE_AVATAR_BAD_FORMAT")

            let noFileForm = MultipartTestBody(
                boundary: "empty-boundary", fields: [("note", "x")],
                filename: "", mimeType: "image/png", bytes: Data()
            )
            let noFile = try await client.send(
                .post, headers: avatarHeaders(key, contentType: noFileForm.contentType),
                to: "/internal/agent-api/profile/avatar"
            ) { request in
                request.body = .init(data: noFileForm.body)
            }
            #expect(noFile.status == .badRequest)
            #expect(object(noFile)["error"] as? String == "No avatar file provided")

            // The `send` capability gates the profile upload.
            var readonlyHeaders = avatarHeaders(readonlyKey, contentType: profileForm.contentType)
            let profileDenied = try await client.send(
                .post, headers: readonlyHeaders, to: "/internal/agent-api/profile/avatar"
            ) { request in
                request.body = .init(data: profileForm.body)
            }
            #expect(profileDenied.status == .forbidden)
            #expect(object(profileDenied)["requiredCapability"] as? String == "send")

            // Server avatar: only a server owner/admin agent may edit the profile.
            let serverForm = MultipartTestBody(
                filename: "server.png", mimeType: "image/png", bytes: png
            )
            let notAdmin = try await client.send(
                .post, headers: avatarHeaders(key, contentType: serverForm.contentType),
                to: "/internal/agent-api/server/avatar"
            ) { request in
                request.body = .init(data: serverForm.body)
            }
            #expect(notAdmin.status == .forbidden)
            #expect(object(notAdmin)["error"] as? String == "Agent requires editServerSettings capability to edit the server profile")

            accounts.oauth.setAgentRole(serverId: serverId, agentId: agent, role: "owner")
            let serverAvatar = try await client.send(
                .post, headers: avatarHeaders(key, contentType: serverForm.contentType),
                to: "/internal/agent-api/server/avatar"
            ) { request in
                request.body = .init(data: serverForm.body)
            }
            #expect(serverAvatar.status == .ok)
            let serverBody = object(serverAvatar)
            #expect(serverBody["id"] as? String == serverId)
            #expect(serverBody["name"] as? String == "Agent Avatar")
            let serverAvatarUrl = try #require(serverBody["avatarUrl"] as? String)
            #expect(serverAvatarUrl.hasPrefix("/api/avatars/server-\(serverId)/"))

            // Legacy machine route: same authority, machine key plus path agent.
            var machineHeaders = HTTPFields()
            machineHeaders[.authorization] = "Bearer \(machineKey)"
            machineHeaders[.contentType] = serverForm.contentType
            let legacyAvatar = try await client.send(
                .post, headers: machineHeaders, to: "/internal/agent/\(agent)/server/avatar"
            ) { request in
                request.body = .init(data: serverForm.body)
            }
            #expect(legacyAvatar.status == .ok)
            #expect(object(legacyAvatar)["id"] as? String == serverId)

            var missingHeaders = HTTPFields()
            missingHeaders[.contentType] = serverForm.contentType
            let missingAuth = try await client.send(
                .post, headers: missingHeaders, to: "/internal/agent/\(agent)/server/avatar"
            ) { request in
                request.body = .init(data: serverForm.body)
            }
            #expect(missingAuth.status == .unauthorized)
            #expect(object(missingAuth)["error"] as? String == "Missing machine API key")
        }
    }
}
