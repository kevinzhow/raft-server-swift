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
        return (201, [:], Data("{\"id\":\"ticket-1\",\"status\":\"open\"}".utf8))
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
            return (201, [:], Data("{\"session_token\":\"hrps_v1_api-test-session\",\"expires_at\":\(Int(Date().timeIntervalSince1970) + 30),\"reporter_integration_id\":\"legacy\",\"scopes\":[\"feedback:read\"]}".utf8))
        }
        if url.contains("/reporter-feedback?") {
            capture.listCount += 1
            capture.listAuthorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return (200, ["Server-Timing": "hands_session_verify;dur=1.0, hands_list;dur=2.0"], Data("{\"tickets\":[],\"next_cursor\":null,\"unread_total\":0}".utf8))
        }
        return (404, [:], Data("{}".utf8))
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
                let timing = response.headers[HTTPField.Name("Server-Timing")!] ?? ""
                #expect(timing.contains("hands_session_verify;dur=1.0"))
                #expect(timing.contains("hands_list;dur=2.0"))
            }
            #expect(capture.mintCount == 1)
            #expect(capture.listCount == 2)
            #expect(capture.listAuthorizations.allSatisfy { $0 == "Bearer hrps_v1_api-test-session" })

            let anonymous = try await client.get(URI(string: "/api/product-feedback/tickets"))
            #expect(anonymous.status == .unauthorized)
        }
    }
}

@Test func productFeedbackClosesCanonicalTicketsAndRejectsNonImageReplies() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111645"
    accounts.addAccount(id: userId, email: "feedback-close@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    accounts.setHandsFeedbackForTesting(baseURL: "https://hands.test", appId: "raft-web", appToken: "t", appSlug: "raft-web")
    accounts.setHandsConversationForTesting(enabled: true, appToken: "hands_conversation_test")
    final class Capture: @unchecked Sendable { var urls: [String] = []; var closeBody: String = ""; var reporterId: String = "" }
    let capture = Capture()
    accounts.setHandsFeedbackUpstreamForTesting { request in
        let url = request.url?.absoluteString ?? ""
        capture.urls.append(url)
        if url.hasSuffix("/reporter-feedback/session") {
            return (201, [:], Data("{\"session_token\":\"hrps_v1_api-test-session\",\"expires_at\":\(Int(Date().timeIntervalSince1970) + 30)}".utf8))
        }
        if url.hasSuffix("/close") {
            capture.closeBody = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            capture.reporterId = request.value(forHTTPHeaderField: "x-hands-reporter-id") ?? ""
            return (200, [:], Data("{\"id\":\"33333333-3333-4333-8333-333333333333\",\"status\":\"closed\",\"closure_reason\":\"completed\",\"duplicate_of_ticket_id\":null,\"updated_at\":1700000000030,\"changed\":true}".utf8))
        }
        return (404, [:], Data("{}".utf8))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let ticketId = "33333333-3333-4333-8333-333333333333"
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            let closed = try await client.send(.post, headers: headers, to: URI(string: "/api/product-feedback/tickets/\(ticketId)/close")) { request in
                request.body = .init(string: "{\"reason\":\"completed\"}")
            }
            #expect(closed.status == .ok)
            let closedBody = (try? JSONSerialization.jsonObject(with: Data((closed.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(closedBody["status"] as? String == "closed")
            #expect(capture.closeBody == "{\"reason\":\"completed\"}")
            #expect(capture.reporterId.range(of: "^[A-Za-z0-9_-]{16,200}$", options: .regularExpression) != nil)

            let invalid = try await client.send(.post, headers: headers, to: URI(string: "/api/product-feedback/tickets/not-a-uuid/close")) { request in
                request.body = .init(string: "{\"reason\":\"completed\"}")
            }
            #expect(invalid.status == .notFound)
            let invalidBody = (try? JSONSerialization.jsonObject(with: Data((invalid.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(invalidBody["code"] as? String == "feedback_not_found")
            #expect(!capture.urls.contains { $0.contains("not-a-uuid") })

            let boundary = "reply-boundary"
            let replyBody = """
            --\(boundary)\r
            Content-Disposition: form-data; name="body"\r
            \r
            Here is the requested reproduction.\r
            --\(boundary)\r
            Content-Disposition: form-data; name="attachments"; filename="notes.txt"\r
            Content-Type: text/plain\r
            \r
            private\r
            --\(boundary)--\r
            """
            var replyHeaders = HTTPFields()
            replyHeaders[.authorization] = "Bearer \(token)"
            replyHeaders[.contentType] = "multipart/form-data; boundary=\(boundary)"
            let reply = try await client.send(.post, headers: replyHeaders, to: URI(string: "/api/product-feedback/tickets/\(ticketId)/comments")) { request in
                request.body = .init(string: replyBody)
            }
            #expect(reply.status == .badRequest)
            let replyJSON = (try? JSONSerialization.jsonObject(with: Data((reply.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(replyJSON["code"] as? String == "feedback_attachment_type_invalid")
        }
    }
}


@Test func attributionIsOmittedWhenTheClaimedServerWasDeleted() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111646"
    let serverId = "33333333-3333-4333-8333-333333333686"
    accounts.addAccount(id: userId, email: "feedback-deleted-server@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "deleted-server", name: "Deleted Server", ownerId: userId)
    accounts.oauth.deleteServer(id: serverId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    accounts.setHandsFeedbackForTesting(baseURL: "https://hands.test", appId: "raft-web", appToken: "t", appSlug: "raft-web")
    final class Capture: @unchecked Sendable { var bodies: [String] = [] }
    let capture = Capture()
    accounts.setHandsFeedbackUpstreamForTesting { request in
        capture.bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        return (201, [:], Data("{\"id\":\"ticket-deleted-server\",\"status\":\"open\"}".utf8))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let boundary = "deleted-server-boundary"
            let body = """
            --\(boundary)\r
            Content-Disposition: form-data; name="type"\r
            \r
            problem\r
            --\(boundary)\r
            Content-Disposition: form-data; name="message"\r
            \r
            Deleted server attribution.\r
            --\(boundary)\r
            Content-Disposition: form-data; name="submission_id"\r
            \r
            dddddddd-dddd-4ddd-8ddd-dddddddddddd\r
            --\(boundary)\r
            Content-Disposition: form-data; name="metadata"\r
            \r
            {}\r
            --\(boundary)--\r
            """
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.post, headers: headers, to: URI(string: "/api/product-feedback")) { request in
                request.body = .init(string: body)
            }
            #expect(response.status == .created)
            #expect(capture.bodies.count == 1)
            #expect(capture.bodies.last?.contains("reporter_attribution") == false)
        }
    }
}
