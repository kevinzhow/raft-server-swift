import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func slackBridgeFailsClosedWithoutProviderRuntime() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111391"
    let serverId = "33333333-3333-4333-8333-333333333528"
    accounts.addAccount(id: ownerId, email: "slack-bridge@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "slack-bridge", name: "Slack Bridge", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"slack-bridge@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let start = try await client.send(.post, headers: headers, to: "/api/slack-bridge/oauth/start") { request in
                request.body = .init(string: "{\"registrationId\":\"00000000-0000-4000-8000-000000000001\",\"serverGrantId\":\"00000000-0000-4000-8000-000000000002\",\"grantEpoch\":1}")
            }
            #expect(start.status == .serviceUnavailable)
            let startBody = try JSONSerialization.jsonObject(with: Data((start.body.string ?? "").utf8)) as? [String: Any]
            #expect(startBody?["ok"] as? Bool == false)
            #expect(startBody?["code"] as? String == "slack_bridge_provider_unavailable")

            let provisioning = try await client.send(.get, headers: headers, to: "/api/slack-bridge/provisioning")
            #expect(provisioning.status == .serviceUnavailable)
            let provisioningBody = try JSONSerialization.jsonObject(with: Data((provisioning.body.string ?? "").utf8)) as? [String: Any]
            #expect(provisioningBody?["code"] as? String == "slack_bridge_provider_unavailable")

            let callback = try await client.send(.get, headers: headers, to: "/api/slack-bridge/oauth/callback?state=missing&code=provider-code")
            #expect(callback.status == .serviceUnavailable)

            var eventHeaders = headers
            eventHeaders[.contentType] = "application/json"
            let events = try await client.send(.post, headers: eventHeaders, to: "/api/slack-bridge/events") { request in
                request.body = .init(string: "{\"type\":\"url_verification\"}")
            }
            #expect(events.status == .serviceUnavailable)
        }
    }
}
