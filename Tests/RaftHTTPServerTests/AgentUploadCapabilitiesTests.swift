import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentUploadCapabilitiesReportTheServerPlan() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111531"
    let serverId = "33333333-3333-4333-8333-333333333612"
    accounts.addAccount(id: ownerId, email: "agent-upload-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-upload", name: "Agent Upload", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "upload-agent")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "upload")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            let response = try await client.send(.get, headers: headers, to: "/internal/agent-api/attachment-upload-capabilities")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["directUploadEnabled"] as? Bool == false)
            #expect(body?["directUploadThresholdBytes"] == nil || body?["directUploadThresholdBytes"] is NSNull)
            #expect(body?["maxBytes"] as? Int == 50 * 1024 * 1024)
            #expect(body?["sessionExpiresInSeconds"] == nil || body?["sessionExpiresInSeconds"] is NSNull)

            accounts.oauth.setServerPlan(id: serverId, plan: "pro")
            let pro = try await client.send(.get, headers: headers, to: "/internal/agent-api/attachment-upload-capabilities")
            #expect((try JSONSerialization.jsonObject(with: Data((pro.body.string ?? "").utf8)) as? [String: Any])?["maxBytes"] as? Int == 90 * 1024 * 1024)

            var bad = HTTPFields()
            bad[.authorization] = "Bearer slock_at_invalid"
            #expect(try await client.send(.get, headers: bad, to: "/internal/agent-api/attachment-upload-capabilities").status == .unauthorized)
        }
    }
}
