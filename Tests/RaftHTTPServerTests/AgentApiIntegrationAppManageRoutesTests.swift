import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The credential-surface integration-app management routes:
/// `POST /internal/agent-api/integrations/app/{logo,manage,rotate-secret,transfer-owner}`.
@Test func agentApiIntegrationAppManagementRoutesLockTheContract() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001030001"
    let ownerId = "11111111-1111-4111-8111-000001030001"
    accounts.addAccount(id: ownerId, email: "agent-app-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-app", name: "Agent App", ownerId: ownerId)

    let ownerAgent = accounts.oauth.createAgent(serverId: serverId, name: "AppOwner", runtime: "codex")
    let targetAgent = accounts.oauth.createAgent(serverId: serverId, name: "AppTarget", runtime: "codex")
    let adminAgent = accounts.oauth.createAgent(serverId: serverId, name: "AppAdmin", runtime: "codex")
    let outsiderAgent = accounts.oauth.createAgent(serverId: serverId, name: "AppOutsider", runtime: "codex")
    accounts.oauth.setAgentRole(serverId: serverId, agentId: adminAgent, role: "admin")

    let ownerKey = accounts.mintAgentCredential(agentId: ownerAgent, scopes: ["read"], name: "owner")
    let adminKey = accounts.mintAgentCredential(agentId: adminAgent, scopes: ["read"], name: "admin")
    let outsiderKey = accounts.mintAgentCredential(agentId: outsiderAgent, scopes: ["read"], name: "outsider")

    let created = try accounts.oauth.createClient(
        serverId: serverId, createdByUserId: ownerId, name: "Managed App",
        clientId: "managed-app", appType: "server_local",
        description: "A managed integration app for tests"
    )
    accounts.oauth.addClientMaintainer(clientRecordId: created.id, agentId: ownerAgent)

    let logoOnly = try accounts.oauth.createClient(
        serverId: serverId, createdByUserId: ownerId, name: "Logo App",
        clientId: "logo-app", appType: "server_local", description: "logo app"
    )
    accounts.oauth.addClientMaintainer(clientRecordId: logoOnly.id, agentId: ownerAgent)

    let deletable = try accounts.oauth.createClient(
        serverId: serverId, createdByUserId: ownerId, name: "Delete App",
        clientId: "delete-app", appType: "server_local", description: "delete app"
    )
    accounts.oauth.addClientMaintainer(clientRecordId: deletable.id, agentId: ownerAgent)

    let publishable = try accounts.oauth.createClient(
        serverId: serverId, createdByUserId: ownerId, name: "Publish App",
        clientId: "publish-app", appType: "server_local", description: "publish app"
    )
    accounts.oauth.addClientMaintainer(clientRecordId: publishable.id, agentId: ownerAgent)
    accounts.oauth.reviewClientPublish(clientRecordId: publishable.id, status: "private")

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
            func jsonHeaders(_ token: String) -> HTTPFields {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = "application/json"
                return headers
            }
            func post(_ path: String, _ token: String, _ json: String) async throws -> ClientResponse {
                try await client.send(.post, headers: jsonHeaders(token), to: URI(string: path)) { request in
                    request.body = .init(string: json)
                }
            }

            let logoForm = MultipartTestBody(
                fields: [("clientKey", "logo-app")],
                filename: "logo.png", mimeType: "image/png",
                bytes: Data([0x89, 0x50, 0x4E, 0x47])
            )
            var logoHeaders = jsonHeaders(ownerKey)
            logoHeaders[.contentType] = logoForm.contentType
            let logo = try await client.send(
                .post, headers: logoHeaders, to: "/internal/agent-api/integrations/app/logo"
            ) { request in
                request.body = .init(data: logoForm.body)
            }
            #expect(logo.status == .ok)
            let logoBody = object(logo)
            #expect(logoBody["clientId"] as? String == logoOnly.id)
            #expect(logoBody["clientKey"] as? String == "logo-app")
            #expect((logoBody["logoUrl"] as? String)?.hasPrefix("/api/integration-logos/\(logoOnly.id)/") == true)

            // Authority is owner-or-admin, and an unknown app stays non-enumerating.
            let logoDenied = try await client.send(
                .post, headers: { var h = jsonHeaders(outsiderKey); h[.contentType] = logoForm.contentType; return h }(),
                to: "/internal/agent-api/integrations/app/logo"
            ) { request in
                request.body = .init(data: logoForm.body)
            }
            #expect(logoDenied.status == .forbidden)
            #expect(object(logoDenied)["errorCode"] as? String == "APP_MANAGE_AUTHORITY_REQUIRED")

            let unknown = try await post(
                "/internal/agent-api/integrations/app/rotate-secret", ownerKey,
                "{\"clientKey\":\"nope\"}"
            )
            #expect(unknown.status == .notFound)
            #expect(object(unknown)["error"] as? String == "Integration app not found")

            // Rotate invalidates the previous secret and publishes the plaintext once.
            let oldSecret = created.clientSecret
            let rotated = try await post(
                "/internal/agent-api/integrations/app/rotate-secret", ownerKey,
                "{\"clientKey\":\"managed-app\"}"
            )
            #expect(rotated.status == .ok)
            let rotatedBody = object(rotated)
            let newSecret = try #require(rotatedBody["clientSecret"] as? String)
            #expect(newSecret.hasPrefix("raft_secret_"))
            #expect(rotatedBody["clientKey"] as? String == "managed-app")
            #expect(accounts.oauth.verifyClientSecret(clientKey: "managed-app", clientSecret: oldSecret) == nil)
            #expect(accounts.oauth.verifyClientSecret(clientKey: "managed-app", clientSecret: newSecret) == created.id)

            // Share links are persisted, re-readable and revocable.
            let shareCreated = try await post(
                "/internal/agent-api/integrations/app/manage", ownerKey,
                "{\"clientKey\":\"managed-app\",\"action\":\"share_link_create\"}"
            )
            #expect(shareCreated.status == .ok)
            let shareBody = object(shareCreated)
            let shareLink = try #require(shareBody["link"] as? [String: Any])
            let shareLinkId = try #require(shareLink["id"] as? String)
            #expect((shareBody["shareUrl"] as? String)?.contains("/integration-invites/") == true)
            #expect(shareLink["revokedAt"] is NSNull)

            let shareGet = try await post(
                "/internal/agent-api/integrations/app/manage", ownerKey,
                "{\"clientKey\":\"managed-app\",\"action\":\"share_link_get\"}"
            )
            #expect(shareGet.status == .ok)
            #expect((object(shareGet)["link"] as? [String: Any])?["id"] as? String == shareLinkId)

            let shareRevoked = try await post(
                "/internal/agent-api/integrations/app/manage", ownerKey,
                "{\"clientKey\":\"managed-app\",\"action\":\"share_link_revoke\"}"
            )
            #expect(shareRevoked.status == .ok)
            #expect((object(shareRevoked)["link"] as? [String: Any])?["revokedAt"] is String)

            let shareRevokeAgain = try await post(
                "/internal/agent-api/integrations/app/manage", ownerKey,
                "{\"clientKey\":\"managed-app\",\"action\":\"share_link_revoke\"}"
            )
            #expect(shareRevokeAgain.status == .notFound)
            #expect(object(shareRevokeAgain)["error"] as? String == "Integration app share link not found")

            // Logo reset publishes an explicit null.
            let cleared = try await post(
                "/internal/agent-api/integrations/app/manage", ownerKey,
                "{\"clientKey\":\"logo-app\",\"action\":\"clear_logo\"}"
            )
            #expect(cleared.status == .ok)
            #expect(object(cleared)["logoUrl"] is NSNull)

            // Publish transitions: request, then a second request is refused.
            let publish = try await post(
                "/internal/agent-api/integrations/app/manage", ownerKey,
                "{\"clientKey\":\"publish-app\",\"action\":\"request_publish\"}"
            )
            #expect(publish.status == .ok)
            #expect(object(publish)["publishStatus"] as? String == "publish_requested")

            let publishAgain = try await post(
                "/internal/agent-api/integrations/app/manage", ownerKey,
                "{\"clientKey\":\"publish-app\",\"action\":\"request_publish\"}"
            )
            #expect(publishAgain.status == .conflict)
            #expect(object(publishAgain)["error"] as? String == "Integration app cannot request Marketplace review in its current state")

            // A published app cannot be deleted.
            accounts.oauth.reviewClientPublish(clientRecordId: publishable.id, status: "published")
            let deletePublished = try await post(
                "/internal/agent-api/integrations/app/manage", ownerKey,
                "{\"clientKey\":\"publish-app\",\"action\":\"delete\"}"
            )
            #expect(deletePublished.status == .conflict)
            #expect(object(deletePublished)["error"] as? String == "Published integration apps must request Marketplace removal before deletion")

            let deleted = try await post(
                "/internal/agent-api/integrations/app/manage", ownerKey,
                "{\"clientKey\":\"delete-app\",\"action\":\"delete\"}"
            )
            #expect(deleted.status == .ok)
            #expect(object(deleted)["clientKey"] as? String == "delete-app")
            #expect(accounts.oauth.agentManagedIntegrationClient(
                serverId: serverId, clientKey: "delete-app"
            ) == nil)

            // Transfer: owner transfers to another same-server agent; a repeat by
            // the admin to the current owner is the already_owner outcome.
            let transfer = try await post(
                "/internal/agent-api/integrations/app/transfer-owner", ownerKey,
                "{\"clientKey\":\"managed-app\",\"targetAgent\":\"@AppTarget\"}"
            )
            #expect(transfer.status == .ok)
            let transferBody = object(transfer)
            #expect(transferBody["ownerAgentId"] as? String == targetAgent)
            #expect(transferBody["ownerAgentName"] as? String == "AppTarget")
            #expect(transferBody["ownershipOutcome"] as? String == "transferred")
            #expect((transferBody["auditEventId"] as? String)?.isEmpty == false)

            let alreadyOwner = try await post(
                "/internal/agent-api/integrations/app/transfer-owner", adminKey,
                "{\"clientKey\":\"managed-app\",\"targetAgent\":\"@AppTarget\"}"
            )
            #expect(alreadyOwner.status == .ok)
            #expect(object(alreadyOwner)["ownershipOutcome"] as? String == "already_owner")

            let targetMissing = try await post(
                "/internal/agent-api/integrations/app/transfer-owner", adminKey,
                "{\"clientKey\":\"managed-app\",\"targetAgent\":\"@Nobody\"}"
            )
            #expect(targetMissing.status == .notFound)
            #expect(object(targetMissing)["error"] as? String == "Target agent not found")

            // Contract validation runs before the service.
            let invalidManage = try await post(
                "/internal/agent-api/integrations/app/manage", ownerKey,
                "{\"clientKey\":\"managed-app\",\"action\":\"nope\"}"
            )
            #expect(invalidManage.status == .badRequest)
            #expect(object(invalidManage)["code"] as? String == "agent_api_contract_invalid")
        }
    }
}
