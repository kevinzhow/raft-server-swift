import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct PlatformScene {
    let scene: OAuthScene
    let ownerId: String
    let memberId: String
    let otherOwnerId: String
    let serverId: String
    let otherServerId: String
    let ownerToken: String
    let memberToken: String
    let otherOwnerToken: String
}

private func makePlatformScene(_ suffix: String) -> PlatformScene {
    let scene = OAuthScene()
    let ownerId = "11111111-1111-4111-8111-000002000\(suffix)"
    let memberId = "11111111-1111-4111-8111-000002001\(suffix)"
    let otherOwnerId = "11111111-1111-4111-8111-000002002\(suffix)"
    let serverId = "33333333-3333-4333-8333-000002000\(suffix)"
    let otherServerId = "33333333-3333-4333-8333-000002001\(suffix)"
    scene.auth.addAccount(id: ownerId, email: "platform-owner-\(suffix)@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: ownerId)
    scene.auth.addAccount(id: memberId, email: "platform-member-\(suffix)@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: memberId)
    scene.auth.addAccount(id: otherOwnerId, email: "platform-other-\(suffix)@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: otherOwnerId)
    scene.oauth.addOwnedServer(id: serverId, slug: "platform-\(suffix)", name: "Platform \(suffix)", ownerId: ownerId)
    scene.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    scene.oauth.addOwnedServer(id: otherServerId, slug: "platform-other-\(suffix)", name: "Platform Other \(suffix)", ownerId: otherOwnerId)
    return PlatformScene(
        scene: scene, ownerId: ownerId, memberId: memberId, otherOwnerId: otherOwnerId,
        serverId: serverId, otherServerId: otherServerId,
        ownerToken: scene.auth.mintAccessTokenForTesting(userId: ownerId),
        memberToken: scene.auth.mintAccessTokenForTesting(userId: memberId),
        otherOwnerToken: scene.auth.mintAccessTokenForTesting(userId: otherOwnerId)
    )
}

private func platformHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func jsonObject(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func jsonArray(_ response: ClientResponse) -> [[String: Any]] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [[String: Any]] ?? []
}

private func createClient(
    _ client: any Client, scene: PlatformScene, name: String = "Platform App",
    clientId: String = "platform-app", description: String = "A platform App"
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    let response = try await client.send(.post, headers: platformHeaders(scene.ownerToken, scene.serverId), to: "/api/integrations/clients") { request in
        request.body = .init(string: """
        {"name":"\(name)","clientId":"\(clientId)","description":"\(description)","homepageUrl":"https://platform.example.test"}
        """)
    }
    return (response.status, jsonObject(response))
}

@Test func clientCreateDeleteAndSecretRotationFollowTheUpstreamContract() async throws {
    let f = makePlatformScene("401")
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            let memberCreate = try await client.send(.post, headers: platformHeaders(f.memberToken, f.serverId), to: "/api/integrations/clients") { request in
                request.body = .init(string: "{\"name\":\"Nope\"}")
            }
            #expect(memberCreate.status == .forbidden)

            let missingName = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients") { request in
                request.body = .init(string: "{}")
            }
            #expect(missingName.status == .badRequest)
            #expect(jsonObject(missingName)["error"] as? String == "name is required")

            let (status, created) = try await createClient(client, scene: f)
            #expect(status == .ok)
            let clientRow = try #require(created["client"] as? [String: Any])
            let secret = try #require(created["clientSecret"] as? String)
            #expect(secret.hasPrefix("raft_secret_"))
            let recordId = try #require(clientRow["id"] as? String)
            #expect(clientRow["clientId"] as? String == "platform-app")
            #expect(clientRow["appType"] as? String == "server_local")
            #expect(clientRow["publishStatus"] as? String == "private")
            #expect(clientRow["category"] as? String == "Other")
            #expect(clientRow["createdAt"] as? String != nil)

            let duplicate = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients") { request in
                request.body = .init(string: "{\"name\":\"Duplicate\",\"clientId\":\"platform-app\"}")
            }
            #expect(duplicate.status == .conflict)
            #expect(jsonObject(duplicate)["error"] as? String == "Client ID is already taken")

            let rotatedResponse = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/regenerate-secret")
            #expect(rotatedResponse.status == .ok)
            let rotated = jsonObject(rotatedResponse)
            #expect(rotated["clientSecret"] as? String != secret)
            #expect((rotated["client"] as? [String: Any])?["id"] as? String == recordId)

            let deletedResponse = try await client.send(.delete, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)")
            #expect(deletedResponse.status == .ok)
            let deleted = jsonObject(deletedResponse)
            #expect(deleted["id"] as? String == recordId)
            let secondDelete = try await client.send(.delete, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)")
            #expect(secondDelete.status == .notFound)
        }
    }
}

@Test func publishRequestsRequireADescriptionAndFollowTheLifecycle() async throws {
    let f = makePlatformScene("402")
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            let (_, body) = try await createClient(client, scene: f, name: "No Description", clientId: "no-description", description: "")
            let recordId = try #require((body["client"] as? [String: Any])?["id"] as? String)
            let refused = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/request-publish")
            #expect(refused.status == .badRequest)
            #expect(jsonObject(refused)["error"] as? String == "description is required before requesting marketplace review")

            let (_, described) = try await createClient(client, scene: f, name: "Described", clientId: "described")
            let describedId = try #require((described["client"] as? [String: Any])?["id"] as? String)
            let publish = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(describedId)/request-publish")
            #expect(publish.status == .ok)
            #expect(jsonObject(publish)["publishStatus"] as? String == "publish_requested")

            let offline = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(describedId)/request-unpublish")
            #expect(offline.status == .notFound)

            f.scene.oauth.setClientAppType(clientRecordId: describedId, appType: "third_party_global")
            f.scene.oauth.setClientPublishStatusForTesting(clientRecordId: describedId, status: "published")
            let unpublish = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(describedId)/request-unpublish")
            #expect(unpublish.status == .ok)
            #expect(jsonObject(unpublish)["publishStatus"] as? String == "unpublish_requested")
        }
    }
}

@Test func privateShareLinkAndInviteInstallOnAnotherOwnedServer() async throws {
    let f = makePlatformScene("403")
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            let (_, created) = try await createClient(client, scene: f, name: "Shared App", clientId: "shared-app")
            let recordId = try #require((created["client"] as? [String: Any])?["id"] as? String)

            let noLink = try await client.get(URI(string: "/api/integrations/clients/\(recordId)/share-link"), headers: platformHeaders(f.ownerToken, f.serverId))
            #expect(noLink.status == .notFound)
            #expect(jsonObject(noLink)["error"] as? String == "OAuth client share link not found")

            let createdLinkResponse = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/share-link") { request in
                request.body = .init(string: "{\"expiresInDays\":7}")
            }
            #expect(createdLinkResponse.status == .ok)
            let createdLink = jsonObject(createdLinkResponse)
            let token = try #require(createdLink["token"] as? String)
            #expect(token.hasPrefix("raft_share_"))
            let link = try #require(createdLink["link"] as? [String: Any])
            #expect(link["clientId"] as? String == recordId)
            #expect(link["revokedAt"] is NSNull)

            let active = try await client.get(URI(string: "/api/integrations/clients/\(recordId)/share-link"), headers: platformHeaders(f.ownerToken, f.serverId))
            #expect(active.status == .ok)
            #expect(jsonObject(active)["id"] as? String == link["id"] as? String)

            let invite = try await client.get(URI(string: "/api/integration-invites/\(token)"), headers: platformHeaders(f.otherOwnerToken, f.serverId))
            #expect(invite.status == .ok)
            let inviteBody = jsonObject(invite)
            #expect((inviteBody["client"] as? [String: Any])?["id"] as? String == recordId)
            #expect((inviteBody["manageableServers"] as? [[String: Any]])?.contains { $0["id"] as? String == f.otherServerId } == true)

            let missingServer = try await client.send(.post, headers: platformHeaders(f.otherOwnerToken, f.otherServerId), to: "/api/integration-invites/\(token)/install") { request in
                request.body = .init(string: "{}")
            }
            #expect(missingServer.status == .badRequest)
            #expect(jsonObject(missingServer)["error"] as? String == "serverId is required")

            let installedResponse = try await client.send(.post, headers: platformHeaders(f.otherOwnerToken, f.otherServerId), to: "/api/integration-invites/\(token)/install") { request in
                request.body = .init(string: "{\"serverId\":\"\(f.otherServerId)\"}")
            }
            #expect(installedResponse.status == .ok)
            #expect((jsonObject(installedResponse)["client"] as? [String: Any])?["installedAt"] as? String != nil)

            let notManageable = try await client.send(.post, headers: platformHeaders(f.memberToken, f.serverId), to: "/api/integration-invites/\(token)/install") { request in
                request.body = .init(string: "{\"serverId\":\"\(f.serverId)\"}")
            }
            #expect(notManageable.status == .forbidden)

            let revoked = try await client.send(.delete, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/share-link")
            #expect(revoked.status == .ok)
            #expect(jsonObject(revoked)["revokedAt"] as? String != nil)
            let gone = try await client.get(URI(string: "/api/integration-invites/\(token)"), headers: platformHeaders(f.otherOwnerToken, f.serverId))
            #expect(gone.status == .notFound)
        }
    }
}

@Test func appNotificationPermissionsAndWebhookExposeTruthfulState() async throws {
    let f = makePlatformScene("404")
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            let (_, created) = try await createClient(client, scene: f, name: "Notify App", clientId: "notify-app")
            let recordId = try #require((created["client"] as? [String: Any])?["id"] as? String)

            let badEvent = try await client.send(.put, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/app-notifications/permissions") { request in
                request.body = .init(string: "{\"groups\":[\"server\"],\"events\":[\"agent.status_changed\"]}")
            }
            #expect(badEvent.status == .badRequest)
            #expect(jsonObject(badEvent)["error"] as? String == "Event agent.status_changed requires group agent")

            let permissions = try await client.send(.put, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/app-notifications/permissions") { request in
                request.body = .init(string: "{\"groups\":[\"server\",\"channel\"],\"events\":[\"thread.created\",\"server.member_added\"]}")
            }
            #expect(permissions.status == .ok)
            let permissionBody = jsonObject(permissions)
            #expect(permissionBody["state"] as? String == "active")
            #expect(permissionBody["requires_marketplace_review"] as? Bool == false)
            #expect(permissionBody["current_groups"] as? [String] == ["channel", "server"])
            #expect(permissionBody["current_events"] as? [String] == ["server.member_added", "thread.created"])
            #expect(permissionBody["invalidated_installation_count"] as? Int == 0)
            #expect(permissionBody["request_revision_id"] as? String != nil)

            let webhook = try await client.send(.put, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/app-notifications/webhook") { request in
                request.body = .init(string: "{\"endpointUrl\":\"https://hooks.example.test/raft\"}")
            }
            #expect(webhook.status == .badRequest)
            #expect(jsonObject(webhook)["error"] as? String == "RAFT_APP_WEBHOOK_ENCRYPTION_KEY is required")

            let badURL = try await client.send(.put, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/app-notifications/webhook") { request in
                request.body = .init(string: "{\"endpointUrl\":\"http://127.0.0.1/hook\"}")
            }
            #expect(badURL.status == .badRequest)
            #expect(jsonObject(badURL)["error"] as? String == "endpointUrl must be credential-free HTTPS")

            let rotate = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/app-notifications/webhook/rotate-secret") { request in
                request.body = .init(string: "{}")
            }
            #expect(rotate.status == .badRequest)
            #expect(jsonObject(rotate)["error"] as? String == "RAFT_APP_WEBHOOK_ENCRYPTION_KEY is required")

            let disable = try await client.send(.delete, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/app-notifications/webhook")
            #expect(disable.status == .notFound)
            #expect(jsonObject(disable)["error"] as? String == "Webhook configuration not found")
        }
    }
}

@Test func marketplaceGrantRequiresAnActiveInstallation() async throws {
    let f = makePlatformScene("405")
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            let (_, created) = try await createClient(client, scene: f, name: "Grant App", clientId: "grant-app")
            let recordId = try #require((created["client"] as? [String: Any])?["id"] as? String)

            let missing = try await client.send(.put, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/marketplace/\(recordId)/install/app-notifications/grant")
            #expect(missing.status == .notFound)
            #expect(jsonObject(missing)["error"] as? String == "Active app installation not found")

            _ = try await client.send(.put, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/app-notifications/permissions") { request in
                request.body = .init(string: "{\"groups\":[\"server\"],\"events\":[\"server.member_added\"]}")
            }
            _ = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/share-link") { request in
                request.body = .init(string: "{}")
            }
            let granted = try await client.send(.put, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/marketplace/\(recordId)/install/app-notifications/grant")
            #expect(granted.status == .ok)
            let body = jsonObject(granted)
            #expect(body["installation_id"] as? String != nil)
            #expect(body["approved_groups"] as? [String] == ["server"])
            #expect(body["subscribed_events"] as? [String] == ["server.member_added"])
            #expect(body["grant_revision"] as? Int == 1)
        }
    }
}

@Test func integrationsOverviewListsPendingRequestsAndDenyResolvesThem() async throws {
    let f = makePlatformScene("406")
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            let created = try f.scene.oauth.createClient(
                serverId: f.serverId, createdByUserId: f.memberId, name: "Overview App",
                clientId: "overview-app", description: "Overview", allowedScopes: ["agent:read"]
            )
            let recordId = created.id
            let secret = created.clientSecret
            let agentId = f.scene.oauth.createAgent(serverId: f.serverId, name: "overview-agent")

            let requestResponse = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/oauth/requests/agent") { request in
                request.body = .init(string: """
                {"clientId":"overview-app","clientSecret":"\(secret)","serverSlug":"platform-406","agentId":"\(agentId)","scopes":["agent:read"]}
                """)
            }
            #expect(requestResponse.status == .ok)
            let requestBody = jsonObject(requestResponse)
            let requestId = try #require(requestBody["requestId"] as? String)

            let overview = try await client.get(URI(string: "/api/integrations/overview"), headers: platformHeaders(f.ownerToken, f.serverId))
            #expect(overview.status == .ok)
            let rows = jsonArray(overview)
            let pending = rows.first { $0["id"] as? String == requestId }
            #expect(pending?["type"] as? String == "pending")
            #expect(pending?["clientName"] as? String == "Overview App")
            #expect(pending?["agentId"] as? String == agentId)

            let denied = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/requests/\(requestId)/deny")
            #expect(denied.status == .ok)
            let deniedBody = jsonObject(denied)
            #expect(deniedBody["status"] as? String == "denied")
            #expect(deniedBody["resolvedByUserId"] as? String == f.ownerId)

            let secondDeny = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/requests/\(requestId)/deny")
            #expect(secondDeny.status == .ok)
            #expect(jsonObject(secondDeny)["status"] as? String == "denied")

            let after = try await client.get(URI(string: "/api/integrations/overview"), headers: platformHeaders(f.ownerToken, f.serverId))
            #expect(jsonArray(after).contains { $0["id"] as? String == requestId } == false)
            _ = recordId
        }
    }
}

@Test func logoUploadsStoreServeAndClearThroughAvatarStorage() async throws {
    let f = makePlatformScene("407")
    // 1x1 transparent GIF: the avatar store validates the real image signature.
    let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!
    try await withApp { app in
        configureOAuthScene(app, scene: f.scene)
        try await app.testing { client in
            let (_, created) = try await createClient(client, scene: f, name: "Logo App", clientId: "logo-app")
            let recordId = try #require((created["client"] as? [String: Any])?["id"] as? String)

            let none = try await client.send(.post, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/logo") { request in
                request.body = .init(string: "")
            }
            #expect(none.status == .badRequest)
            #expect(jsonObject(none)["error"] as? String == "No logo file provided")

            let boundary = "raft-boundary-407"
            var headers = platformHeaders(f.ownerToken, f.serverId)
            headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
            var body = Data()
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"logo\"; filename=\"logo.gif\"\r\n".utf8))
            body.append(Data("Content-Type: image/gif\r\n\r\n".utf8))
            body.append(gif)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let upload = try await client.send(.post, headers: headers, to: "/api/integrations/clients/\(recordId)/logo") { request in
                request.body = .init(data: body)
            }
            #expect(upload.status == .ok, "logo body: \(upload.body.string ?? "")")
            let logoURL = try #require(jsonObject(upload)["logoUrl"] as? String)
            #expect(logoURL.wholeMatch(of: /^\/api\/integration-logos\/[0-9a-f-]+\/[0-9a-f]{32}\.webp$/) != nil)

            // Serving the stored object is locked by ProfileAssetStorageTests;
            // this scene mounts only the integrations collection.
            let cleared = try await client.send(.delete, headers: platformHeaders(f.ownerToken, f.serverId), to: "/api/integrations/clients/\(recordId)/logo")
            #expect(cleared.status == .ok)
            #expect(jsonObject(cleared)["logoUrl"] is NSNull)
        }
    }
}
