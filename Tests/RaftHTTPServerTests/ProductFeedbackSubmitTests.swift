import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct SubmitFixture {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001103001"
    let token: String

    init(verified: Bool = true) {
        accounts.addAccount(id: userId, email: "feedback-submit@hands.test", password: "password123")
        if verified { accounts.markEmailVerified(userId: userId) }
        token = accounts.mintAccessTokenForTesting(userId: userId)
    }
}

private func form(_ fields: [String: String]) -> (body: String, contentType: String) {
    let boundary = "raft-submit-boundary"
    var body = ""
    for (name, value) in fields {
        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }
    body += "--\(boundary)--\r\n"
    return (body, "multipart/form-data; boundary=\(boundary)")
}

private func submitForm(_ client: any Client, _ fixture: SubmitFixture, _ fields: [String: String], clientKind: String? = nil) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    let payload = form(fields)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(fixture.token)"
    headers[.contentType] = payload.contentType
    if let clientKind { headers[HTTPField.Name("X-Raft-Client-Kind")!] = clientKind }
    let response = try await client.send(.post, headers: headers, to: URI(string: "/api/product-feedback")) { request in
        request.body = .init(string: payload.body)
    }
    return (response.status, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
}

private func fieldValue(_ body: String, _ name: String) -> String? {
    guard let range = body.range(of: "name=\"\(name)\"") else { return nil }
    let rest = body[range.upperBound...]
    guard let separator = rest.range(of: "\r\n\r\n") else { return nil }
    let after = rest[separator.upperBound...]
    guard let end = after.range(of: "\r\n--") else { return nil }
    return String(after[..<end.lowerBound])
}

@Test func feedbackRequiresVerifiedUserAndRejectsInvalidDraftOrSpoofedNativeAttribution() async throws {
    let unverified = SubmitFixture(verified: false)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: unverified.accounts))
        try await app.testing { client in
            let noAuth = try await client.send(.post, headers: { var h = HTTPFields(); h[.contentType] = "multipart/form-data; boundary=x"; return h }(), to: URI(string: "/api/product-feedback")) { request in
                request.body = .init(string: "--x--\r\n")
            }
            #expect(noAuth.status == .unauthorized)
            let unverifiedResult = try await submitForm(client, unverified, ["type": "idea", "message": "x", "submission_id": "55555555-5555-4555-8555-555555555555", "may_contact": "false"])
            #expect(unverifiedResult.status == .forbidden)
            #expect(unverifiedResult.body["code"] as? String == "account_unverified")
        }
    }

    let fixture = SubmitFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let webhook = try await client.send(.post, headers: { var h = HTTPFields(); h[.contentType] = "application/json"; return h }(), to: URI(string: "/api/internal/hands-feedback/webhook")) { request in
                request.body = .init(string: "{}")
            }
            #expect(webhook.status == .notFound)

            let invalid = try await submitForm(client, fixture, ["type": "idea", "message": "Please add a compact command palette.", "submission_id": "not-a-uuid"])
            #expect(invalid.status == .badRequest)
            #expect(invalid.body["code"] as? String == "feedback_invalid")

            fixture.accounts.setHandsFeedbackForTesting(baseURL: nil, appId: nil, appToken: nil)
            let unconfigured = try await submitForm(client, fixture, ["type": "idea", "message": "Please add a compact command palette.", "submission_id": "55555555-5555-4555-8555-555555555555", "may_contact": "false"])
            #expect(unconfigured.status == .serviceUnavailable)
            #expect(unconfigured.body["code"] as? String == "feedback_not_configured")

            let spoofed = try await submitForm(client, fixture, [
                "type": "problem", "message": "Native attribution should fail closed when spoofed.",
                "submission_id": "66666666-6666-4666-8666-666666666666", "may_contact": "false",
                "metadata": "{\"client_kind\":\"ios\",\"platform\":\"web\",\"client_version\":\"1.0.0\",\"browser\":\"SpoofBrowser\"}",
            ])
            #expect(spoofed.status == .badRequest)
            #expect(spoofed.body["code"] as? String == "feedback_invalid")

            let trusted = try await submitForm(client, fixture, [
                "type": "problem", "message": "Native attribution should reach the config gate when trusted.",
                "submission_id": "77777777-7777-4777-8777-777777777777", "may_contact": "false",
                "metadata": "{\"client_kind\":\"ios\",\"platform\":\"ios\",\"client_version\":\"1.0.0\"}",
            ], clientKind: "ios")
            #expect(trusted.status == .serviceUnavailable)
            #expect(trusted.body["code"] as? String == "feedback_not_configured")
        }
    }
}

@Test func nativeAttributionIsForwardedToHandsMetadataWithAppSlug() async throws {
    for (index, kind) in ["ios", "android"].enumerated() {
        let fake = try FakeHands(status: 201, responseBody: "{\"id\":\"ticket-native\",\"status\":\"open\",\"attachments\":0}")
        defer { fake.stop() }
        let fixture = SubmitFixture()
        fixture.accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(fake.port)", appId: "11111111-1111-4111-8111-111111111111", appToken: "app_token", appSlug: "raft-web")
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
            try await app.testing { client in
                let version = kind == "ios" ? "1.2.3" : "2026.7.26"
                let os = kind == "ios" ? "iOS 18.5" : "Android 15"
                let result = try await submitForm(client, fixture, [
                    "type": "problem", "message": "Native \(kind) feedback should reach Hands.",
                    "submission_id": kind == "ios" ? "88888888-8888-4888-8888-888888888888" : "99999999-9999-4999-8999-999999999999",
                    "may_contact": "false",
                    "metadata": "{\"client_kind\":\"\(kind)\",\"platform\":\"\(kind)\",\"client_version\":\"\(version)\",\"locale\":\"en-US\",\"os_version\":\"\(os)\"}",
                ], clientKind: kind)
                #expect(result.status == .created, Comment(rawValue: "\(kind) \(result.body)"))
                #expect(result.body["id"] as? String == "ticket-native")
                let create = try #require(fake.requests().first { $0.path.contains("/feedback") })
                #expect(create.path == "/public/v2/apps/raft-web/feedback", Comment(rawValue: create.path))
                let metadataJSON = try #require(fieldValue(create.body, "metadata"))
                let metadata = try #require((try JSONSerialization.jsonObject(with: Data(metadataJSON.utf8))) as? [String: Any])
                #expect(metadata["client_kind"] as? String == kind)
                #expect(metadata["product_type"] as? String == kind)
                #expect(metadata["feedback_type"] as? String == "problem")
                #expect(metadata["contact_consent"] as? Bool == false)
                #expect(metadata["locale"] as? String == "en-US")
                #expect(metadata["os_version"] as? String == os)
                for forbidden in ["browser", "viewport", "web_version", "userId", "reporterId", "baseUrl", "appToken"] {
                    #expect(metadata[forbidden] == nil, Comment(rawValue: forbidden))
                }
                _ = index
            }
        }
    }
}
