import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func productFeedbackForwardsReporterAttributionOnlyForMembers() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111642"
    let serverId = "33333333-3333-4333-8333-333333333684"
    let foreignId = "33333333-3333-4333-8333-333333333685"
    accounts.addAccount(id: userId, email: "feedback-member@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "attribution-server", name: "Attribution Server", ownerId: userId)
    accounts.oauth.addOwnedServer(id: foreignId, slug: "foreign-server", name: "Foreign Server", ownerId: "11111111-1111-4111-8111-111111111643")
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    accounts.setHandsFeedbackForTesting(baseURL: "https://hands.test", appId: "raft-web", appToken: "t", appSlug: "raft-web")
    final class Capture: @unchecked Sendable { var bodies: [String] = [] }
    let capture = Capture()
    accounts.setHandsFeedbackUpstreamForTesting { request in
        capture.bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        return (201, Data("{\"id\":\"ticket-1\",\"status\":\"open\"}".utf8))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func submit(_ server: String?, id: String) async throws -> ClientResponse {
                let boundary = "test-boundary"
                let metadata = "{}"
                let body = """
                --\(boundary)\r
                Content-Disposition: form-data; name="type"\r
                \r
                problem\r
                --\(boundary)\r
                Content-Disposition: form-data; name="message"\r
                \r
                Attribution should travel to Hands.\r
                --\(boundary)\r
                Content-Disposition: form-data; name="submission_id"\r
                \r
                \(id)\r
                --\(boundary)\r
                Content-Disposition: form-data; name="may_contact"\r
                \r
                false\r
                --\(boundary)\r
                Content-Disposition: form-data; name="metadata"\r
                \r
                \(metadata)\r
                --\(boundary)--\r
                """
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
                if let server { headers[HTTPField.Name("X-Server-Id")!] = server }
                return try await client.send(.post, headers: headers, to: URI(string: "/api/product-feedback")) { request in
                    request.body = .init(string: body)
                }
            }
            let attributed = try await submit(serverId, id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            #expect(attributed.status == .created)
            #expect(capture.bodies.last?.contains("reporter_attribution") == true)
            #expect(capture.bodies.last?.contains("attribution-server") == true)
            #expect(capture.bodies.last?.contains("feedback-member") == true)
            #expect(capture.bodies.last?.contains(userId) == true)

            let foreign = try await submit(foreignId, id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
            #expect(foreign.status == .created)
            #expect(capture.bodies.last?.contains("reporter_attribution") == false)

            let none = try await submit(nil, id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
            #expect(none.status == .created)
            #expect(capture.bodies.last?.contains("reporter_attribution") == false)

            let malformed = try await submit("not-a-uuid", id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")
            #expect(malformed.status == .created)
            #expect(capture.bodies.last?.contains("reporter_attribution") == false)
        }
    }
}

@Test func productFeedbackTicketsReusesOneReporterSession() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111644"
    accounts.addAccount(id: userId, email: "feedback-tickets@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    accounts.setHandsFeedbackForTesting(baseURL: "https://hands.test", appId: "raft-web", appToken: "t", appSlug: "raft-web")
    accounts.setHandsConversationForTesting(enabled: true, appToken: "hands_conversation_test")
    final class Capture: @unchecked Sendable {
        var mintCount = 0
        var listCount = 0
        var listAuthorizations: [String] = []
    }
    let capture = Capture()
    accounts.setHandsFeedbackUpstreamForTesting { request in
        let url = request.url?.absoluteString ?? ""
        if url.hasSuffix("/reporter-feedback/session") {
            capture.mintCount += 1
            return (201, Data("{\"session_token\":\"hrps_v1_api-test-session\",\"expires_at\":\(Int(Date().timeIntervalSince1970) + 30),\"reporter_integration_id\":\"legacy\",\"scopes\":[\"feedback:read\"]}".utf8))
        }
        if url.contains("/reporter-feedback?") {
            capture.listCount += 1
            capture.listAuthorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return (200, Data("{\"tickets\":[],\"next_cursor\":null,\"unread_total\":0}".utf8))
        }
        return (404, Data("{}".utf8))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            for _ in 0..<2 {
                let response = try await client.get(URI(string: "/api/product-feedback/tickets"), headers: headers)
                #expect(response.status == .ok)
                let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                #expect(body["tickets"] as? [Any] != nil)
                #expect(body["next_cursor"] is NSNull)
                #expect(body["unread_total"] as? Int == 0)
            }
            #expect(capture.mintCount == 1)
            #expect(capture.listCount == 2)
            #expect(capture.listAuthorizations.allSatisfy { $0 == "Bearer hrps_v1_api-test-session" })

            let anonymous = try await client.get(URI(string: "/api/product-feedback/tickets"))
            #expect(anonymous.status == .unauthorized)
        }
    }
}
