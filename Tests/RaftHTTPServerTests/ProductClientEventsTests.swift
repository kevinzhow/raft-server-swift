import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func freshClientEventTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

private func clientEventJSON(_ event: String, properties: String, session: String, timestamp: String? = nil) -> String {
    let timestamp = timestamp ?? freshClientEventTimestamp()
    return "{\"uuid\":\"\(UUID().uuidString.lowercased())\",\"event\":\"\(event)\",\"timestamp\":\"\(timestamp)\",\"client_session_id\":\"\(session)\",\"properties\":\(properties)}"
}

@Test func clientEventsRespectSharingAndDropUnregisteredRows() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111242"
    let serverId = "33333333-3333-4333-8333-333333333438"
    let sessionId = "8f6c3e2a-1b4d-4c5e-9f7a-2b3c4d5e6f70"
    accounts.addAccount(id: ownerId, email: "client-events-242@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "client-events-242", name: "Client Events", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"client-events-242@slock.test\",\"password\":\"password123\"}")
            }
            let loginBody = try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any]
            let token = loginBody?["accessToken"] as? String ?? ""

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let config = try await client.send(.get, headers: headers, to: "/api/product-events/config")
            #expect(config.body.string == "{\"clientEventsAllowed\":false}")

            func batch(_ body: String, headers extra: [String: String] = [:]) async throws -> ClientResponse {
                var requestHeaders = headers
                for (name, value) in extra { requestHeaders[HTTPField.Name(name)!] = value }
                return try await client.send(.post, headers: requestHeaders, to: "/api/product-events/batch") { request in
                    request.body = .init(string: body)
                }
            }

            let denied = try await batch("{\"source\":\"web\",\"events\":[\(clientEventJSON("activity_open", properties: "{\"from\":\"rail\"}", session: sessionId))]}")
            #expect(denied.status == .accepted)
            #expect(denied.body.string == "{\"accepted\":0}")

            accounts.setShareUsageData(userId: ownerId, value: true)
            let allowedConfig = try await client.send(.get, headers: headers, to: "/api/product-events/config")
            #expect(allowedConfig.body.string == "{\"clientEventsAllowed\":true}")

            let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
            let body = """
            {"source":"web","app_version":"1.2.3","events":[\
            \(clientEventJSON("activity_open", properties: "{\"from\":\"rail\"}", session: sessionId)),\
            \(clientEventJSON("activity_open", properties: "{\"from\":\"rail\",\"text\":\"hello\"}", session: sessionId)),\
            \(clientEventJSON("button_clicked", properties: "{}", session: sessionId)),\
            \(clientEventJSON("activity_mark", properties: "{\"action\":\"done\"}", session: sessionId, timestamp: "2020-01-01T00:00:00.000Z"))\
            ]}
            """
            let accepted = try await batch(body, headers: ["User-Agent": userAgent, "CloudFront-Viewer-Country": "DE"])
            #expect(accepted.status == .accepted)
            #expect(accepted.body.string == "{\"accepted\":1}")

            let rows = accounts.recordedClientEvents(serverId: serverId)
            #expect(rows.count == 1)
            let row = rows.first
            #expect(row?.event == "activity_open")
            #expect(row?.analyticsId == accounts.analyticsId(userId: ownerId))
            #expect(row?.source == "web")
            #expect(row?.sessionId == sessionId)
            #expect(row?.appVersion == "1.2.3")
            let properties = try JSONSerialization.jsonObject(with: Data((row?.propertiesJSON ?? "{}").utf8)) as? [String: Any]
            #expect(properties?["from"] as? String == "rail")
            #expect(properties?["$browser"] as? String == "chrome")
            #expect(properties?["$browser_version"] as? Int == 141)
            #expect(properties?["$os"] as? String == "windows")
            #expect(properties?["$device_type"] as? String == "desktop")
            #expect(properties?["$country"] as? String == "DE")
            #expect((row?.propertiesJSON ?? "").contains("Win64") == false)
            #expect((row?.propertiesJSON ?? "").contains(ownerId) == false)

            let malformed = try await batch("{\"source\":\"web\",\"events\":[{\"event\":\"activity_open\"}]}")
            #expect(malformed.status == .badRequest)

            let eventUUID = UUID().uuidString.lowercased()
            let duplicate = "{\"uuid\":\"\(eventUUID)\",\"event\":\"activity_open\",\"timestamp\":\"\(freshClientEventTimestamp())\",\"client_session_id\":\"\(UUID().uuidString.lowercased())\",\"properties\":{\"from\":\"rail\"}}"
            let first = try await batch("{\"source\":\"web\",\"events\":[\(duplicate),\(duplicate)]}")
            #expect(first.body.string == "{\"accepted\":1}")
            let again = try await batch("{\"source\":\"web\",\"events\":[\(duplicate)]}")
            #expect(again.body.string == "{\"accepted\":0}")
            #expect(accounts.recordedClientEvents(serverId: serverId).count == 2)

            let badSession = try await batch("{\"source\":\"web\",\"events\":[{\"uuid\":\"\(UUID().uuidString.lowercased())\",\"event\":\"activity_open\",\"timestamp\":\"2026-10-31T00:00:00.000Z\",\"client_session_id\":\"tab-1 <script>\",\"properties\":{}}]}")
            #expect(badSession.status == .badRequest)
            let badVersion = try await batch("{\"source\":\"web\",\"app_version\":\"1.0 (beta)\",\"events\":[\(clientEventJSON("activity_open", properties: "{}", session: sessionId))]}")
            #expect(badVersion.status == .badRequest)
        }
    }
}
