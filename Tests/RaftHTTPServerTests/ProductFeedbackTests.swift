import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func feedbackForm(_ fields: [(String, String)]) -> (String, String) {
    let boundary = "raft-feedback-boundary"
    var body = ""
    for (name, value) in fields {
        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }
    body += "--\(boundary)--\r\n"
    return (body, "multipart/form-data; boundary=\(boundary)")
}

@Test func productFeedbackFailsClosedWithoutHandsConfiguration() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111243"
    accounts.addAccount(id: ownerId, email: "feedback-243@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let anonymous = try await client.send(.post, headers: HTTPFields(), to: "/api/product-feedback")
            #expect(anonymous.status == .unauthorized)

            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"feedback-243@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""

            func submit(_ fields: [(String, String)]) async throws -> ClientResponse {
                let (body, contentType) = feedbackForm(fields)
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = contentType
                return try await client.send(.post, headers: headers, to: "/api/product-feedback") { request in
                    request.body = .init(string: body)
                }
            }

            let invalid = try await submit([
                ("type", "idea"),
                ("message", "Please add a compact command palette."),
                ("submission_id", "not-a-uuid"),
            ])
            #expect(invalid.status == .badRequest)
            let invalidBody = try JSONSerialization.jsonObject(with: Data((invalid.body.string ?? "").utf8)) as? [String: Any]
            #expect(invalidBody?["code"] as? String == "feedback_invalid")

            let unconfigured = try await submit([
                ("type", "idea"),
                ("message", "Please add a compact command palette."),
                ("submission_id", "55555555-5555-4555-8555-555555555555"),
                ("may_contact", "false"),
            ])
            #expect(unconfigured.status == .serviceUnavailable)
            let unconfiguredBody = try JSONSerialization.jsonObject(with: Data((unconfigured.body.string ?? "").utf8)) as? [String: Any]
            #expect(unconfiguredBody?["code"] as? String == "feedback_not_configured")

            let spoofed = try await submit([
                ("type", "problem"),
                ("message", "Native attribution should fail closed when spoofed."),
                ("submission_id", "66666666-6666-4666-8666-666666666666"),
                ("may_contact", "false"),
                ("metadata", "{\"client_kind\":\"ios\",\"platform\":\"web\",\"client_version\":\"1.0.0\",\"browser\":\"SpoofBrowser\"}"),
            ])
            #expect(spoofed.status == .badRequest)
            let spoofedBody = try JSONSerialization.jsonObject(with: Data((spoofed.body.string ?? "").utf8)) as? [String: Any]
            #expect(spoofedBody?["code"] as? String == "feedback_invalid")

            let webhook = try await client.send(.post, headers: loginHeaders, to: "/api/internal/hands-feedback/webhook") { request in
                request.body = .init(string: "{}")
            }
            #expect(webhook.status == .notFound)
        }
    }
}
