import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func authSceneInvitePreviewAndAcceptanceShareTheSceneOwners() async throws {
    let scene = AuthScene()
    let ownerId = UUID().uuidString.lowercased()
    let userId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    let inviteToken = "scene-invite-" + UUID().uuidString.lowercased()
    scene.auth.addAccount(id: ownerId, email: "scene.owner@invite.test", password: "password123")
    scene.auth.addAccount(id: userId, email: "scene.guest@invite.test", password: "password123")
    scene.invites.addOwnedServer(id: serverId, slug: "scene-invites", name: "Scene Invites", ownerId: ownerId)
    scene.invites.seedEmailInvite(id: UUID().uuidString.lowercased(), serverId: serverId, email: "scene.guest@invite.test", role: "member", token: inviteToken)
    let token = scene.auth.mintAccessTokenForTesting(userId: userId)
    #expect(scene.invites.inviteCount(serverId: serverId) == 1)
    #expect(scene.invites.memberRole(serverId: serverId, userId: userId) == nil)
    try await withAuthSceneApp(scene) { client in
        let preview = try await client.get(URI(string: "/api/auth/invite-info?token=\(inviteToken)"))
        #expect(preview.status == .ok)
        let expected = "{\"serverId\":\"\(serverId)\",\"serverName\":\"Scene Invites\",\"serverSlug\":\"scene-invites\",\"humanSeatLimitReached\":false,\"humanSeatLimitMessage\":null,\"memberCount\":1,\"agentCount\":0,\"insideCountsHidden\":false,\"agreement\":null}"
        #expect(preview.body.string == expected)
        #expect(preview.headers[.contentType] == "application/json; charset=utf-8")
        #expect(preview.headers[.contentLength] == String(expected.utf8.count))
        let joined = try await authScenePost(client, "/api/auth/accept-invite", token: token, body: "{\"token\":\"\(inviteToken)\"}")
        #expect(joined.status == .ok)
        #expect(joined.body.string == "{\"ok\":true,\"serverId\":\"\(serverId)\"}")
        #expect(scene.invites.memberRole(serverId: serverId, userId: userId) == "member")
        #expect(scene.invites.inviteCount(serverId: serverId) == 0)
    }
}

enum AuthSceneDirectoryBranch: CaseIterable, Sendable {
    case success, missingServer, wrongEmail
}

@Test(arguments: AuthSceneDirectoryBranch.allCases)
func authSceneOptionalPublicDirectoryPreservesExactFallbackBranch(branch: AuthSceneDirectoryBranch) async throws {
    let scene = AuthScene()
    let ownerId = UUID().uuidString.lowercased()
    let userId = UUID().uuidString.lowercased()
    let privateServer = UUID().uuidString.lowercased()
    let publicServer = UUID().uuidString.lowercased()
    let inviteToken = "directory-invite-" + UUID().uuidString.lowercased()
    scene.auth.addAccount(id: ownerId, email: "directory.owner@scene.test", password: "password123")
    scene.auth.addAccount(id: userId, email: "directory.guest@scene.test", password: "password123")
    let token = scene.auth.mintAccessTokenForTesting(userId: userId)
    scene.invites.addOwnedServer(id: privateServer, slug: "private-scene", name: "Private Scene", ownerId: ownerId)
    scene.invites.seedEmailInvite(id: UUID().uuidString.lowercased(), serverId: privateServer, email: "directory.guest@scene.test", role: "member", token: inviteToken)

    // The optional directory is an existing external domain object. Seed it
    // through its actual API and give the Feature this same reference.
    let directory = PublicServerDirectory()
    directory.addServer(id: publicServer, name: "Public Scene", slug: "public-scene", ownerId: ownerId, ownerToken: "public-owner-token")
    directory.addAccount(id: userId, email: "directory.guest@scene.test", token: token)
    directory.addEmailInvite(
        serverId: branch == .missingServer ? UUID().uuidString.lowercased() : publicServer,
        email: branch == .wrongEmail ? "different@scene.test" : "directory.guest@scene.test",
        role: "guest", rawToken: inviteToken, expiresAt: Date().addingTimeInterval(3600)
    )
    // Missing/unknown tokens are 400. A valid invite whose server is absent is
    // the real 404 that must fall through to the supplied invite Service.
    try await withAuthSceneApp(scene, publicServerDirectory: directory) { client in
        let response = try await authScenePost(client, "/api/auth/accept-invite", token: token, body: "{\"token\":\"\(inviteToken)\"}")
        #expect(response.headers[.contentType] == "application/json; charset=utf-8")
        switch branch {
        case .success:
            #expect(response.status == .ok)
            #expect(response.body.string == "{\"serverId\":\"\(publicServer)\",\"serverName\":\"Public Scene\"}")
            #expect(directory.memberRole(serverId: publicServer, userId: userId) == "guest")
            #expect(scene.invites.memberRole(serverId: privateServer, userId: userId) == nil)
            #expect(scene.invites.inviteCount(serverId: privateServer) == 1)
        case .missingServer:
            #expect(response.status == .ok)
            #expect(response.body.string == "{\"ok\":true,\"serverId\":\"\(privateServer)\"}")
            #expect(directory.memberRole(serverId: publicServer, userId: userId) == nil)
            #expect(scene.invites.memberRole(serverId: privateServer, userId: userId) == "member")
            #expect(scene.invites.inviteCount(serverId: privateServer) == 0)
        case .wrongEmail:
            // The production Feature catches this non-404 DomainError and its
            // existing respond boundary renders it; no test error encoder runs.
            #expect(response.status == .badRequest)
            #expect(response.body.string == #"{"error":"This invite was sent to a different email address"}"#)
            #expect(directory.memberRole(serverId: publicServer, userId: userId) == nil)
            #expect(scene.invites.memberRole(serverId: privateServer, userId: userId) == nil)
            #expect(scene.invites.inviteCount(serverId: privateServer) == 1)
        }
        #expect(response.headers[.contentLength] == String((response.body.string ?? "").utf8.count))
    }
}
