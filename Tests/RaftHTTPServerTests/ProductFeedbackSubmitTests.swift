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

@Test func feedbackWebhookIsGoneAndUnconfiguredNativeFailsClosed() async throws {
    let fixture = SubmitFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let webhook = try await client.send(.post, headers: headers, to: URI(string: "/api/internal/hands-feedback/webhook")) { request in
                request.body = .init(string: "{}")
            }
            #expect(webhook.status == .notFound)

            fixture.accounts.setHandsFeedbackForTesting(baseURL: nil, appId: nil, appToken: nil)
            let fields: [String: String] = [
                "type": "problem",
                "message": "Native attribution should fail closed when spoofed.",
                "submission_id": "66666666-6666-4666-8666-666666666666",
                "may_contact": "false",
                "metadata": "{\"client_kind\":\"ios\",\"platform\":\"ios\",\"client_version\":\"1.0.0\"}",
            ]
            let trusted = try await submitForm(client, fixture, fields, clientKind: "ios")
            #expect(trusted.status == .serviceUnavailable)
            #expect(trusted.body["code"] as? String == "feedback_not_configured")

            let spoofedFields: [String: String] = [
                "type": "problem",
                "message": "Spoof.",
                "submission_id": "66666666-6666-4666-8666-666666666667",
                "metadata": "{\"client_kind\":\"ios\",\"platform\":\"web\",\"browser\":\"SpoofBrowser\"}",
            ]
            let spoofed = try await submitForm(client, fixture, spoofedFields, clientKind: "ios")
            #expect(spoofed.status == .badRequest)
            #expect(spoofed.body["code"] as? String == "feedback_invalid")
        }
    }
}

@Test func agentReportIssueCarriesCanonicalFeedbackReportId() async throws {
    let fixture = SubmitFixture()
    fixture.accounts.setHandsFeedbackForTesting(baseURL: "https://hands.test", appId: "raft-web", appToken: "t", appSlug: "raft-web")
    final class Capture: @unchecked Sendable { var bodies: [String] = [] }
    let capture = Capture()
    fixture.accounts.setHandsFeedbackUpstreamForTesting { request in
        capture.bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        return (201, [:], Data("{\"id\":\"ticket-report\",\"status\":\"open\"}".utf8))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let base: [String: String] = [
                "type": "problem", "message": "Issue report for Helper",
                "may_contact": "false",
            ]
            var rejectedFields = base
            rejectedFields["submission_id"] = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
            rejectedFields["feedback_report_id"] = "report-1"
            let rejected = try await submitForm(client, fixture, rejectedFields)
            #expect(rejected.status == .badRequest)
            #expect(rejected.body["code"] as? String == "feedback_invalid")

            var acceptedFields = base
            acceptedFields["submission_id"] = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
            acceptedFields["feedback_report_id"] = "0d9b2c4e-6f1a-4b3c-9d8e-7f6a5b4c3d2e"
            let accepted = try await submitForm(client, fixture, acceptedFields)
            #expect(accepted.status == .created)
            let metadata = fieldValue(capture.bodies.last ?? "", "metadata") ?? ""
            #expect(metadata.contains("0d9b2c4e-6f1a-4b3c-9d8e-7f6a5b4c3d2e"))
            #expect(metadata.contains("agent.report_issue"))
        }
    }
}

@Test func nativeAttributionForwardsProductTypeForIOSAndAndroid() async throws {
    for kind in ["ios", "android"] {
        let fixture = SubmitFixture()
        fixture.accounts.setHandsFeedbackForTesting(baseURL: "https://hands.test", appId: "raft-web", appToken: "t", appSlug: "raft-web")
        final class Capture: @unchecked Sendable { var bodies: [String] = [] }
        let capture = Capture()
        fixture.accounts.setHandsFeedbackUpstreamForTesting { request in
            capture.bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            return (201, [:], Data("{\"id\":\"ticket-native\",\"status\":\"open\"}".utf8))
        }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
            try await app.testing { client in
                let fields: [String: String] = [
                    "type": "problem",
                    "message": "Native \(kind) feedback should reach Hands.",
                    "submission_id": kind == "ios" ? "88888888-8888-4888-8888-888888888888" : "99999999-9999-4999-8999-999999999999",
                    "may_contact": "false",
                    "metadata": "{\"client_kind\":\"\(kind)\",\"platform\":\"\(kind)\",\"client_version\":\"1.0.0\"}",
                ]
                let result = try await submitForm(client, fixture, fields, clientKind: kind)
                #expect(result.status == .created)
                let metadata = fieldValue(capture.bodies.last ?? "", "metadata") ?? ""
                #expect(metadata.contains("\"product_type\":\"\(kind)\""))
                #expect(metadata.contains("\"feedback_type\":\"problem\""))
            }
        }
    }
}

@Test func trustedClientKindHeaderMustMatchNativeMetadata() async throws {
    let fixture = SubmitFixture()
    fixture.accounts.setHandsFeedbackForTesting(baseURL: "https://hands.test", appId: "raft-web", appToken: "t", appSlug: "raft-web")
    var upstreamCalls = 0
    fixture.accounts.setHandsFeedbackUpstreamForTesting { _ in
        upstreamCalls += 1
        return (201, [:], Data("{\"id\":\"ticket\",\"status\":\"open\"}".utf8))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let base: [String: String] = [
                "type": "problem", "message": "Native attribution.",
                "submission_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "metadata": "{\"client_kind\":\"ios\",\"platform\":\"ios\"}",
            ]
            let absent = try await submitForm(client, fixture, base, clientKind: nil)
            #expect(absent.status == .badRequest)
            #expect(absent.body["code"] as? String == "feedback_invalid")
            let mismatched = try await submitForm(client, fixture, base, clientKind: "android")
            #expect(mismatched.status == .badRequest)
            #expect(upstreamCalls == 0)

            fixture.accounts.setHandsFeedbackForTesting(baseURL: nil, appId: nil, appToken: nil)
            let trusted = try await submitForm(client, fixture, base, clientKind: "ios")
            #expect(trusted.status == .serviceUnavailable)
            #expect(trusted.body["code"] as? String == "feedback_not_configured")
        }
    }
}

@Test func feedbackProjectsUpstreamErrorsAndSanitizesTiming() async throws {
    let fixture = SubmitFixture()
    fixture.accounts.setHandsFeedbackForTesting(baseURL: "https://hands.test", appId: "raft-web", appToken: "t", appSlug: "raft-web")
    fixture.accounts.setHandsFeedbackUpstreamForTesting { _ in
        (403, ["Server-Timing": "hands_auth;dur=10.0, hands_preflight;dur=20.0, ticket_id;dur=1, hands_list;desc=secret;dur=2"], Data("{\"error\":\"trusted reporter identity requires feedback:write permission for this app\",\"secret\":\"must not be projected\"}".utf8))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let fields: [String: String] = [
                "type": "problem", "message": "Error projection.",
                "submission_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            ]
            let denied = try await submitForm(client, fixture, fields)
            #expect(denied.status == .serviceUnavailable)
            #expect(denied.body["code"] as? String == "feedback_integration_unavailable")
            #expect(denied.body["upstream_status"] as? Int == 403)
            #expect(denied.body["upstream_error"] as? String == "trusted reporter identity requires feedback:write permission for this app")
            let serialized = String(decoding: try JSONSerialization.data(withJSONObject: denied.body), as: UTF8.self)
            #expect(!serialized.contains("secret"))
        }
    }

    let timingFixture = SubmitFixture()
    timingFixture.accounts.setHandsFeedbackForTesting(baseURL: "https://hands.test", appId: "raft-web", appToken: "t", appSlug: "raft-web")
    timingFixture.accounts.setHandsFeedbackUpstreamForTesting { _ in
        (201, ["Server-Timing": "hands_auth;dur=10.0, hands_preflight;dur=20.0, hands_commit;dur=30.0, hands_postcommit;dur=40.0, ticket_id;dur=1, hands_list;desc=secret;dur=2"], Data("{\"id\":\"ticket-timing\",\"status\":\"open\"}".utf8))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: timingFixture.accounts))
        try await app.testing { client in
            let fields: [String: String] = [
                "type": "problem", "message": "Timing.",
                "submission_id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            ]
            let payload = form(fields)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(timingFixture.token)"
            headers[.contentType] = payload.contentType
            let response = try await client.send(.post, headers: headers, to: URI(string: "/api/product-feedback")) { request in
                request.body = .init(string: payload.body)
            }
            #expect(response.status == .created)
            let timing = response.headers[HTTPField.Name("Server-Timing")!] ?? ""
            #expect(timing.hasPrefix("raft_feedback_hands;dur="))
            #expect(timing.contains("hands_auth;dur=10.0"))
            #expect(timing.contains("hands_preflight;dur=20.0"))
            #expect(timing.contains("hands_commit;dur=30.0"))
            #expect(timing.contains("hands_postcommit;dur=40.0"))
            #expect(!timing.contains("ticket_id"))
            #expect(!timing.contains("secret"))
        }
    }
}
