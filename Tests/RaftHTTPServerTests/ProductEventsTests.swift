import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func onboardingWizardEventIsSanitizedAndRecorded() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111241"
    let serverId = "33333333-3333-4333-8333-333333333437"
    accounts.addAccount(id: ownerId, email: "onboarding-241@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "onboarding-241", name: "Onboarding", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"onboarding-241@slock.test\",\"password\":\"password123\"}")
            }
            let body = try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any]
            let token = body?["accessToken"] as? String ?? ""

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.post, headers: headers, to: "/api/product-events/onboarding-wizard") { request in
                request.body = .init(string: "{\"eventType\":\"onboarding_wizard.primary_clicked\",\"idempotencyKey\":\"onboarding-event-test-primary\",\"metadata\":{\"step_id\":\"referral-source\",\"wizard_version\":\"owner-wizard-v3\",\"session_id\":\"session-123\",\"action\":\"submit_referral\",\"result\":\"twitter_x\",\"reason\":\"ignored-but-allowed\",\"latency_ms\":123.4,\"raw_text\":\"must not be stored\"}}")
            }
            #expect(response.status == .noContent)

            let rows = accounts.recordedProductEvents(subjectId: serverId)
            #expect(rows.count == 1)
            let row = rows.first
            #expect(row?.subjectType == "onboarding_wizard")
            #expect(row?.eventType == "onboarding_wizard.primary_clicked")
            #expect(row?.actorType == "human")
            #expect(row?.actorId == ownerId)
            #expect(row?.source == "web")
            #expect(row?.idempotencyKey == "onboarding-event-test-primary")
            let metadata = try JSONSerialization.jsonObject(with: Data((row?.metadataJSON ?? "{}").utf8)) as? [String: Any]
            #expect(metadata?["step_id"] as? String == "referral-source")
            #expect(metadata?["wizard_version"] as? String == "owner-wizard-v3")
            #expect(metadata?["session_id"] as? String == "session-123")
            #expect(metadata?["action"] as? String == "submit_referral")
            #expect(metadata?["result"] as? String == "twitter_x")
            #expect(metadata?["reason"] as? String == "ignored-but-allowed")
            #expect(metadata?["latency_ms"] as? Int == 123)
            #expect(metadata?["raw_text"] == nil)

            let push = try await client.send(.post, headers: headers, to: "/api/product-events/onboarding-wizard") { request in
                request.body = .init(string: "{\"eventType\":\"onboarding_wizard.step_shown\",\"metadata\":{\"step_id\":\"enable-notifications\",\"wizard_version\":\"owner-wizard-v3\",\"session_id\":\"session-123\"}}")
            }
            #expect(push.status == .badRequest)
            let pushBody = try JSONSerialization.jsonObject(with: Data((push.body.string ?? "").utf8)) as? [String: Any]
            #expect(((pushBody?["error"] as? String) ?? "").contains("tracked onboarding wizard step"))
            #expect(accounts.recordedProductEvents(subjectId: serverId).count == 1)

            accounts.setShareUsageData(userId: ownerId, value: false)
            let optedOut = try await client.send(.post, headers: headers, to: "/api/product-events/onboarding-wizard") { request in
                request.body = .init(string: "{\"eventType\":\"onboarding_wizard.step_shown\",\"idempotencyKey\":\"opted-out\",\"metadata\":{\"step_id\":\"create-agent\"}}")
            }
            #expect(optedOut.status == .noContent)
            #expect(accounts.recordedProductEvents(subjectId: serverId).count == 1)

            accounts.setShareUsageData(userId: ownerId, value: nil)
            accounts.oauth.setServerProductAnalytics(id: serverId, enabled: false)
            let workspaceOff = try await client.send(.post, headers: headers, to: "/api/product-events/onboarding-wizard") { request in
                request.body = .init(string: "{\"eventType\":\"onboarding_wizard.step_shown\",\"idempotencyKey\":\"workspace-off\",\"metadata\":{\"step_id\":\"create-agent\"}}")
            }
            #expect(workspaceOff.status == .noContent)
            #expect(accounts.recordedProductEvents(subjectId: serverId).count == 1)
        }
    }
}
