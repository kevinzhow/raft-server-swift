import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Synchronization
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Byte-exact wire contract of the ticket routes after the move onto
/// `FeedbackMultiAppService` + `respond`: status, body text and the complete
/// header set (including the headers a reply must NOT carry).
@Suite
struct FeedbackMultiAppRouteTests {
    private static let ticketId = "33333333-3333-4333-8333-333333333333"
    private static let attachmentId = "55555555-5555-4555-8555-555555555555"
    private static let userId = "11111111-1111-4111-8111-000001105777"

    private func accounts(
        upstream: @escaping @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data)
    ) -> (EmailLoginDirectory, String) {
        let accounts = EmailLoginDirectory()
        accounts.addAccount(id: Self.userId, email: "ticket-routes@hands.test", password: "password123")
        accounts.markEmailVerified(userId: Self.userId)
        accounts.setHandsFeedbackForTesting(
            baseURL: "https://hands.test",
            appId: "11111111-1111-4111-8111-111111111111",
            appToken: "t",
            appSlug: "raft-web"
        )
        accounts.setHandsFeedbackUpstreamForTesting { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "PUT", path.hasSuffix("/route-subject") {
                return (201, [:], Data("{\"changed\":true,\"subject_version\":\"v1\"}".utf8))
            }
            return upstream(request)
        }
        return (accounts, accounts.mintAccessTokenForTesting(userId: Self.userId))
    }

    private func run(
        _ accounts: EmailLoginDirectory,
        _ body: (any Client) async throws -> Void
    ) async throws {
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: accounts
            ))
            try await app.testing { client in try await body(client) }
        }
    }

    private func headers(_ token: String?, contentType: String? = nil) -> HTTPFields {
        var fields = HTTPFields()
        if let token { fields[.authorization] = "Bearer \(token)" }
        if let contentType { fields[.contentType] = contentType }
        return fields
    }

    private func name(_ value: String) -> HTTPField.Name { HTTPField.Name(value)! }

    private func headerNames(_ headers: HTTPFields) -> Set<String> {
        Set(headers.map { $0.name.rawName.lowercased() })
    }

    @Test func listPublishesTheSortedRewrittenBodyWithTheExactHeaderSet() async throws {
        let (accounts, token) = accounts { request in
            #expect(request.url?.absoluteString.hasSuffix("/reporter-feedback?limit=50") == true)
            return (200, ["Server-Timing": "hands_list;dur=2.0"], Data("{\"unread_total\":0,\"tickets\":[],\"next_cursor\":null}".utf8))
        }
        try await run(accounts) { client in
            let response = try await client.get(URI(string: "/api/product-feedback/tickets"), headers: headers(token))
            #expect(response.status == .ok)
            // No cursor secret and a null cursor: the upstream text is relayed unchanged.
            #expect(response.body.string == "{\"unread_total\":0,\"tickets\":[],\"next_cursor\":null}")
            #expect(response.headers[.contentType] == "application/json; charset=utf-8")
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[.contentLength] == "50")
            let timing = response.headers[name("Server-Timing")] ?? ""
            #expect(timing.hasPrefix("raft_feedback_hands;dur="))
            #expect(timing.hasSuffix(", hands_list;dur=2.0"))
            #expect(response.headers[name("X-Robots-Tag")] == nil)
            #expect(headerNames(response.headers).isSuperset(of: ["content-type", "cache-control", "content-length", "server-timing"]))
        }
    }

    @Test func closeRelaysTheUpstreamStatusAndBodyWithoutTimingOrRobotsHeaders() async throws {
        let seen = Mutex<[String]>([])
        let (accounts, token) = accounts { request in
            seen.withLock { $0.append("\(request.httpMethod ?? "") \(request.url?.path ?? "") \(String(decoding: request.httpBody ?? Data(), as: UTF8.self))") }
            return (201, [:], Data("{\"closed\":true}".utf8))
        }
        try await run(accounts) { client in
            let response = try await client.send(
                .post,
                headers: headers(token, contentType: "application/json"),
                to: URI(string: "/api/product-feedback/tickets/\(Self.ticketId)/close")
            ) { $0.body = .init(string: "{\"reason\":\"completed\",\"extra\":1}") }
            #expect(response.status == .created)
            #expect(response.body.string == "{\"closed\":true}")
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[name("Server-Timing")] == nil)
            #expect(response.headers[name("X-Robots-Tag")] == nil)
            #expect(response.headers[.contentLength] == "15")
        }
        #expect(seen.withLock { $0 }.last?.hasSuffix("/close {\"reason\":\"completed\"}") == true)
    }

    @Test func closeAcceptsABodyWithoutAContentType() async throws {
        let (accounts, token) = accounts { _ in (200, [:], Data("{}".utf8)) }
        try await run(accounts) { client in
            let response = try await client.send(
                .post,
                headers: headers(token),
                to: URI(string: "/api/product-feedback/tickets/\(Self.ticketId)/close")
            ) { $0.body = .init(string: "{\"reason\":\"no_longer_needed\"}") }
            #expect(response.status == .ok)
            let bad = try await client.send(
                .post,
                headers: headers(token),
                to: URI(string: "/api/product-feedback/tickets/\(Self.ticketId)/close")
            ) { $0.body = .init(string: "{\"reason\":\"nope\"}") }
            #expect(bad.status == .badRequest)
            #expect(bad.body.string == "{\"error\":\"Feedback close reason is invalid\",\"code\":\"feedback_invalid\"}")
            #expect(bad.headers[name("X-Robots-Tag")] == "noindex, nofollow")
            #expect(bad.headers[.contentType] == "application/json; charset=utf-8")
            let missing = try await client.send(
                .post,
                headers: headers(token),
                to: URI(string: "/api/product-feedback/tickets/\(Self.ticketId)/close")
            )
            #expect(missing.status == .badRequest)
        }
    }

    @Test func rateLimitedPublishesRetryAfterAndNoRobotsTag() async throws {
        let (accounts, token) = accounts { _ in (429, ["Retry-After": "17"], Data()) }
        try await run(accounts) { client in
            let response = try await client.get(
                URI(string: "/api/product-feedback/tickets/\(Self.ticketId)"),
                headers: headers(token)
            )
            #expect(response.status == .tooManyRequests)
            #expect(response.body.string == "{\"error\":\"Too many feedback requests. Please try again later.\",\"code\":\"feedback_rate_limited\"}")
            #expect(response.headers[name("Retry-After")] == "17")
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[name("X-Robots-Tag")] == nil)
        }
    }

    @Test func attachmentKeepsTheUpstreamTypeAndPublishesTheHardenedHeaders() async throws {
        let (accounts, token) = accounts { _ in
            (200, ["Content-Type": "image/png", "Content-Disposition": "inline; filename=\"a.png\""], Data("PNGDATA".utf8))
        }
        try await run(accounts) { client in
            let response = try await client.get(
                URI(string: "/api/product-feedback/tickets/\(Self.ticketId)/attachments/\(Self.attachmentId)"),
                headers: headers(token)
            )
            #expect(response.status == .ok)
            #expect(response.body.string == "PNGDATA")
            #expect(response.headers[.contentType] == "image/png")
            #expect(response.headers[name("X-Content-Type-Options")] == "nosniff")
            #expect(response.headers[.cacheControl] == "private, no-store")
            #expect(response.headers[name("Content-Disposition")] == "inline; filename=\"a.png\"")
            #expect(response.headers[.contentLength] == "7")
            #expect(response.headers[name("X-Robots-Tag")] == nil)
        }
    }

    @Test func authorizationAndValidationErrorsKeepTheStandardJSONHeaders() async throws {
        let (accounts, token) = accounts { _ in (200, [:], Data("{}".utf8)) }
        try await run(accounts) { client in
            let anonymous = try await client.get(URI(string: "/api/product-feedback/tickets"))
            #expect(anonymous.status == .unauthorized)
            #expect(anonymous.body.string == "{\"error\":\"Unauthorized\"}")
            #expect(anonymous.headers[name("X-Robots-Tag")] == "noindex, nofollow")
            #expect(anonymous.headers[.contentType] == "application/json; charset=utf-8")
            #expect(anonymous.headers[.contentLength] == "24")
            #expect(anonymous.headers[.cacheControl] == nil)

            let notFound = try await client.get(
                URI(string: "/api/product-feedback/tickets/not-a-uuid"),
                headers: headers(token)
            )
            #expect(notFound.status == .notFound)
            #expect(notFound.body.string == "{\"error\":\"Feedback ticket not found\",\"code\":\"feedback_not_found\"}")

            let nonImage = try await client.send(
                .post,
                headers: headers(token, contentType: "multipart/form-data; boundary=b"),
                to: URI(string: "/api/product-feedback/tickets/\(Self.ticketId)/comments")
            ) {
                $0.body = .init(string: "--b\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nx\r\n--b--\r\n")
            }
            #expect(nonImage.status == .badRequest)
            #expect(nonImage.body.string == "{\"error\":\"Only image attachments are supported\",\"code\":\"feedback_attachment_type_invalid\"}")
        }
    }
}
