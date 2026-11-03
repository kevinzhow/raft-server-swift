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

private func productEventsFixture(_ suffix: String) -> (accounts: EmailLoginDirectory, serverId: String, token: String, ownerId: String) {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-0000014000\(suffix)"
    let serverId = "33333333-3333-4333-8333-0000014000\(suffix)"
    accounts.addAccount(id: ownerId, email: "product-events-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "product-events-\(suffix)", name: "Product Events", ownerId: ownerId)
    return (accounts, serverId, accounts.mintAccessTokenForTesting(userId: ownerId), ownerId)
}

private func clientEventsRequest(
    _ client: any Client,
    token: String,
    serverId: String,
    method: HTTPRequest.Method,
    path: String,
    body: String? = nil,
    userAgent: String? = nil,
    country: String? = nil
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    if body != nil { headers[.contentType] = "application/json" }
    if let userAgent { headers[HTTPField.Name("User-Agent")!] = userAgent }
    if let country { headers[HTTPField.Name("CloudFront-Viewer-Country")!] = country }
    let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

private let clientEventSession = "8f6c3e2a-1b4d-4c5e-9f7a-2b3c4d5e6f70"

private func clientEvent(_ event: String, properties: String, uuid: String, timestamp: String = "2026-11-04T00:00:00.000Z") -> String {
    "{\"uuid\":\"\(uuid)\",\"event\":\"\(event)\",\"timestamp\":\"\(timestamp)\",\"client_session_id\":\"\(clientEventSession)\",\"properties\":\(properties)}"
}

@Test func clientEventsAreRefusedUntilTheUserSharesUsageData() async throws {
    let f = productEventsFixture("01")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let config = try await clientEventsRequest(client, token: f.token, serverId: f.serverId, method: .get, path: "/api/product-events/config")
            #expect(config.status == .ok)
            #expect(config.body["clientEventsAllowed"] as? Bool == false)

            let res = try await clientEventsRequest(
                client, token: f.token, serverId: f.serverId, method: .post,
                path: "/api/product-events/batch",
                body: "{\"source\":\"web\",\"events\":[\(clientEvent("activity_open", properties: "{\"from\":\"rail\"}", uuid: "11111111-1111-4111-8111-111111111111"))]}"
            )
            #expect(res.status == .accepted)
            #expect(res.body["accepted"] as? Int == 0)
            #expect(f.accounts.recordedClientEvents(serverId: f.serverId).isEmpty)
        }
    }
}

@Test func registeredClientEventsStoreOnlyTheAnalyticsIdentityWithDerivedContext() async throws {
    let f = productEventsFixture("02")
    f.accounts.setShareUsageData(userId: f.ownerId, value: true)
    let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    let batch = """
    {"source":"web","app_version":"1.2.3","events":[\
    \(clientEvent("activity_open", properties: "{\"from\":\"rail\"}", uuid: "22222222-2222-4222-8222-222222222222")),\
    \(clientEvent("activity_open", properties: "{\"from\":\"rail\",\"text\":\"hello\"}", uuid: "33333333-3333-4333-8333-333333333333")),\
    \(clientEvent("button_clicked", properties: "{}", uuid: "44444444-4444-4444-8444-444444444444")),\
    \(clientEvent("activity_mark", properties: "{\"action\":\"done\"}", uuid: "55555555-5555-4555-8555-555555555555", timestamp: "2020-01-01T00:00:00.000Z"))\
    ]}
    """
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let config = try await clientEventsRequest(client, token: f.token, serverId: f.serverId, method: .get, path: "/api/product-events/config")
            #expect(config.body["clientEventsAllowed"] as? Bool == true)

            let res = try await clientEventsRequest(
                client, token: f.token, serverId: f.serverId, method: .post,
                path: "/api/product-events/batch", body: batch,
                userAgent: chrome, country: "DE"
            )
            #expect(res.status == .accepted)
            #expect(res.body["accepted"] as? Int == 1, "unknown property, unregistered event and a stale timestamp are skipped")

            let rows = f.accounts.recordedClientEvents(serverId: f.serverId)
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.event == "activity_open")
            #expect(row.serverId == f.serverId)
            #expect(row.source == "web")
            #expect(row.sessionId == clientEventSession)
            #expect(row.appVersion == "1.2.3")
            #expect(!row.analyticsId.isEmpty)
            #expect(row.analyticsId != f.ownerId, "the Raft user id must not reach the store")
            #expect(!row.propertiesJSON.contains(f.ownerId))
            #expect(!row.propertiesJSON.contains("Win64"), "the raw user agent must not reach the store")
            let properties = (try? JSONSerialization.jsonObject(with: Data(row.propertiesJSON.utf8))) as? [String: Any] ?? [:]
            #expect(properties["from"] as? String == "rail")
            #expect(properties["$browser"] as? String == "chrome")
            #expect((properties["$browser_version"] as? NSNumber)?.intValue == 141)
            #expect(properties["$os"] as? String == "windows")
            #expect(properties["$device_type"] as? String == "desktop")
            #expect(properties["$country"] as? String == "DE")
        }
    }
}

@Test func malformedClientEventBatchesAreRejectedAndDuplicatesDropped() async throws {
    let f = productEventsFixture("03")
    f.accounts.setShareUsageData(userId: f.ownerId, value: true)
    let event = clientEvent("activity_open", properties: "{\"from\":\"rail\"}", uuid: "66666666-6666-4666-8666-666666666666")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let malformed = try await clientEventsRequest(
                client, token: f.token, serverId: f.serverId, method: .post,
                path: "/api/product-events/batch", body: "{\"source\":\"web\",\"events\":[{\"event\":\"activity_open\"}]}"
            )
            #expect(malformed.status == .badRequest)

            let repeated = try await clientEventsRequest(
                client, token: f.token, serverId: f.serverId, method: .post,
                path: "/api/product-events/batch",
                body: "{\"source\":\"web\",\"events\":[\(event),\(event)]}"
            )
            #expect(repeated.status == .accepted)
            #expect(repeated.body["accepted"] as? Int == 1, "a repeated uuid inside one batch is stored once")

            let again = try await clientEventsRequest(
                client, token: f.token, serverId: f.serverId, method: .post,
                path: "/api/product-events/batch", body: "{\"source\":\"web\",\"events\":[\(event)]}"
            )
            #expect(again.body["accepted"] as? Int == 0, "a recently seen uuid is dropped")
            #expect(f.accounts.recordedClientEvents(serverId: f.serverId).count == 1)

            let badSession = try await clientEventsRequest(
                client, token: f.token, serverId: f.serverId, method: .post,
                path: "/api/product-events/batch",
                body: "{\"source\":\"web\",\"events\":[{\"uuid\":\"77777777-7777-4777-8777-777777777777\",\"event\":\"activity_open\",\"timestamp\":\"2026-11-04T00:00:00.000Z\",\"client_session_id\":\"tab-1 <script>\",\"properties\":{\"from\":\"rail\"}}]}"
            )
            #expect(badSession.status == .badRequest)

            let badVersion = try await clientEventsRequest(
                client, token: f.token, serverId: f.serverId, method: .post,
                path: "/api/product-events/batch",
                body: "{\"source\":\"web\",\"app_version\":\"1.0 (beta)\",\"events\":[\(clientEvent("activity_open", properties: "{\"from\":\"rail\"}", uuid: "88888888-8888-4888-8888-888888888888"))]}"
            )
            #expect(badVersion.status == .badRequest)
        }
    }
}
