import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// `productFeedback.multiApp.api` (7 upstream cases): per-source Hands apps
/// selected from `HANDS_FEEDBACK_APPS` behind the `product_feedback_multi_app`
/// flag, shared reporter/route-root/cursor secrets, route-subject binding and
/// per-source ticket/cursor isolation.
///
/// Every request goes through the production `FeedbackFeature` routes and
/// `FeedbackMultiAppService`; nothing is mounted over them.
@Suite
struct ProductFeedbackMultiAppTests {
    private static let androidAppId = "a48a84f8-04ed-4db3-9297-189a14a36afc"
    private static let androidIntegrationId = "a7df6737-1452-4680-a23a-c321277f53f4"
    private static let legacyAppId = "11111111-1111-4111-8111-111111111111"
    private static let iosAppId = "fbfaceca-6d27-47e1-9c20-e56a39535339"
    private static let androidTicketId = "33333333-3333-4333-8333-333333333333"

    // MARK: - Fake Hands upstream

    struct CapturedRequest: Sendable {
        let method: String
        let url: String
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }

        var path: String {
            URL(string: url)?.path ?? url
        }
    }

    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [CapturedRequest] = []

        func append(_ request: URLRequest) {
            let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { result, pair in
                result[pair.key.lowercased()] = pair.value
            }
            let captured = CapturedRequest(
                method: request.httpMethod ?? "",
                url: request.url?.absoluteString ?? "",
                headers: headers,
                body: request.httpBody ?? Data()
            )
            lock.lock(); items.append(captured); lock.unlock()
        }

        func all() -> [CapturedRequest] {
            lock.lock(); defer { lock.unlock() }
            return items
        }

        func reset() {
            lock.lock(); items.removeAll(); lock.unlock()
        }
    }

    private static let allowedTickets: Set<String> = ["\(androidAppId)/\(androidTicketId)"]

    private func fakeHands(_ capture: Capture) -> @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data) {
        { request in
            capture.append(request)
            let path = request.url?.path ?? ""
            let headers = ["Content-Type": "application/json"]
            func json(_ status: Int, _ body: String) -> (Int, [String: String], Data) {
                (status, headers, Data(body.utf8))
            }
            if request.httpMethod == "PUT", path.hasSuffix("/reporter-feedback/route-subject") {
                return json(201, "{\"changed\":true,\"subject_version\":\"v1\"}")
            }
            if request.httpMethod == "POST", path.hasSuffix("/reporter-feedback/session") {
                return json(201, "{\"session_token\":\"hrps_v1_api-test-session\",\"expires_at\":\(Int(Date().timeIntervalSince1970) + 30),\"reporter_integration_id\":\"\(Self.androidIntegrationId)\",\"scopes\":[\"feedback:comment\",\"feedback:read\"]}")
            }
            if request.httpMethod == "POST", path.hasSuffix("/feedback") {
                return json(201, "{\"id\":\"ticket-1\",\"status\":\"open\",\"attachments\":0}")
            }
            // `/api/apps/{app}/reporter-feedback/{ticketId}(/...)` must only exist
            // in the app that owns it, like the real Hands.
            if let range = path.range(of: "^/api/apps/([^/]+)/reporter-feedback/([0-9a-f-]{36})(?:/|$)", options: .regularExpression) {
                let matched = String(path[range])
                let parts = matched.split(separator: "/")
                let appId = parts.count > 2 ? String(parts[2]) : ""
                let ticketId = parts.count > 4 ? String(parts[4]) : ""
                if !Self.allowedTickets.contains("\(appId)/\(ticketId)") {
                    return json(404, "{\"error\":\"not_found\"}")
                }
            }
            if request.httpMethod == "GET", path.hasSuffix("/reporter-feedback") || path.contains("/reporter-feedback?") {
                return json(200, "{\"tickets\":[],\"next_cursor\":\"hands-page-2\",\"unread_total\":0}")
            }
            return json(404, "{\"error\":\"not_found\"}")
        }
    }

    // MARK: - Environment helpers

    private func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func legacyEnvironment(baseURL: String) -> [String: String] {
        [
            "HANDS_FEEDBACK_BASE_URL": baseURL,
            "HANDS_FEEDBACK_APP_SLUG": "raft-web",
            "HANDS_FEEDBACK_CLIENT_KEY": "qk_legacy",
            "HANDS_FEEDBACK_APP_TOKEN": "legacy_app_token",
            "HANDS_FEEDBACK_REPORTER_ID_SECRET": "legacy-reporter-secret",
            "HANDS_FEEDBACK_APP_ID": Self.legacyAppId,
            "HANDS_FEEDBACK_CONVERSATION_APP_TOKEN": "legacy_conversation_token",
            "HANDS_FEEDBACK_CONVERSATION_CREDENTIAL_REVISION": "legacy-revision",
            "HANDS_FEEDBACK_CURSOR_SECRET": "legacy-cursor-secret",
            "HANDS_FEEDBACK_REPORTER_INTEGRATION_ID": "legacy-feedback:\(Self.legacyAppId)",
            "HANDS_FEEDBACK_ROUTE_SUBJECT_KEY_ID": "v1",
            "HANDS_FEEDBACK_ROUTE_SUBJECT_ROOT": base64url(Array(repeating: 1, count: 32)),
        ]
    }

    private func appsJSON(rootBytes: [UInt8] = Array(repeating: 9, count: 32), includeOhos: Bool = false) -> String {
        let shared = "{\"reporter_id_secret\":\"multi-reporter-secret\",\"route_subject_root\":\"\(base64url(rootBytes))\",\"cursor_secret\":\"multi-cursor-secret\"}"
        let ios = "{\"app_slug\":\"raft-feedback-ios\",\"app_id\":\"\(Self.iosAppId)\",\"reporter_integration_id\":\"9414a84b-7b41-44a2-96b5-b3617ec057cc\",\"credential_revision\":\"1\",\"client_key\":\"qk_ios\",\"token\":\"ios_token\"}"
        let android = "{\"app_slug\":\"raft-feedback-android\",\"app_id\":\"\(Self.androidAppId)\",\"reporter_integration_id\":\"\(Self.androidIntegrationId)\",\"credential_revision\":\"1\",\"client_key\":\"qk_android\",\"token\":\"android_token\"}"
        var entries = ["\"shared\":\(shared)", "\"ios\":\(ios)", "\"android\":\(android)"]
        if includeOhos {
            entries.append("\"ohos\":{\"app_slug\":\"raft-feedback-ohos\",\"app_id\":\"00000000-0000-4000-8000-000000000001\",\"reporter_integration_id\":\"00000000-0000-4000-8000-000000000002\",\"credential_revision\":\"1\",\"client_key\":\"qk_ohos\",\"token\":\"ohos_token\"}")
        }
        return "{" + entries.joined(separator: ",") + "}"
    }

    private func accounts(baseURL: String) -> EmailLoginDirectory {
        let accounts = EmailLoginDirectory()
        let userId = "11111111-1111-4111-8111-000001105001"
        accounts.addAccount(id: userId, email: "multi-feedback@hands.test", password: "password123")
        accounts.markEmailVerified(userId: userId)
        accounts.setHandsFeedbackLegacyEnvironmentForTesting(legacyEnvironment(baseURL: baseURL))
        accounts.setHandsFeedbackAppsForTesting(appsJSON())
        return accounts
    }

    private func token(_ accounts: EmailLoginDirectory) -> String {
        accounts.mintAccessTokenForTesting(userId: "11111111-1111-4111-8111-000001105001")
    }

    private func enableMultiApp(_ accounts: EmailLoginDirectory) {
        accounts.createFeatureFlagForTesting(key: FeedbackService.productFeedbackMultiAppFlag, defaultEnabled: true, enabled: true)
    }

    // MARK: - HTTP wiring

    private func withFeedbackApp(
        accounts: EmailLoginDirectory,
        _ run: (any Client) async throws -> Void
    ) async throws {
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: accounts
            ))
            try await app.testing { client in
                try await run(client)
            }
        }
    }

    // MARK: - Request helpers

    private func authHeaders(_ token: String, kind: String? = nil) -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        if let kind { headers[HTTPField.Name("X-Raft-Client-Kind")!] = kind }
        return headers
    }

    private func multipart(_ fields: [String: String], boundary: String = "raft-multi-boundary") -> (String, String) {
        var body = ""
        for (name, value) in fields {
            body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        body += "--\(boundary)--\r\n"
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    private func submitForm(_ kind: String) -> (String, String) {
        multipart([
            "type": "problem",
            "message": "feedback from \(kind)",
            "submission_id": "77777777-7777-4777-8777-777777777777",
            "may_contact": "false",
            "metadata": "{\"client_kind\":\"\(kind)\",\"platform\":\"\(kind)\",\"client_version\":\"1.0.0\"}",
        ])
    }

    private func jsonBody(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func listPath(_ requests: [CapturedRequest], method: String = "GET") -> CapturedRequest? {
        requests.last { $0.method == method && $0.path.contains("/reporter-feedback") && !$0.path.contains("/session") && !$0.path.contains("/route-subject") }
    }

    // MARK: - 1

    @Test func flagOnAndroidSubmitAndListReachAndroidApp() async throws {
        let capture = Capture()
        let accounts = accounts(baseURL: "https://hands.test")
        accounts.setHandsFeedbackUpstreamForTesting(fakeHands(capture))
        enableMultiApp(accounts)
        let token = token(accounts)

        try await withFeedbackApp(accounts: accounts) { client in
            let (body, contentType) = submitForm("android")
            var headers = authHeaders(token, kind: "android")
            headers[.contentType] = contentType
            let submitted = try await client.send(.post, headers: headers, to: URI(string: "/api/product-feedback")) { request in
                request.body = .init(string: body)
            }
            #expect(submitted.status == .created)

            let requests = capture.all()
            let submit = try #require(requests.first { $0.method == "POST" && $0.path.hasSuffix("/feedback") })
            #expect(submit.path == "/public/v2/apps/raft-feedback-android/feedback")
            #expect(submit.header("x-hands-client-key") == "qk_android")
            #expect(submit.header("authorization") == "Bearer android_token")
            let binding = try #require(requests.first { $0.method == "PUT" })
            #expect(binding.path == "/api/apps/\(Self.androidAppId)/reporter-feedback/route-subject")
            #expect(binding.header("authorization") == "Bearer android_token")

            let listed = try await client.get(
                URI(string: "/api/product-feedback/tickets"),
                headers: authHeaders(token, kind: "android")
            )
            #expect(listed.status == .ok)
            let list = try #require(listPath(capture.all()))
            #expect(list.path.hasPrefix("/api/apps/\(Self.androidAppId)/reporter-feedback"))
            let all = capture.all()
            #expect(!all.contains { $0.url.contains(Self.legacyAppId) || $0.url.contains("raft-web") })
            #expect(accounts.productFeedbackRouteCommitmentLabelsForTesting() == ["hands-feedback-route-subject:multi:v1"])
        }
    }

    // MARK: - 2

    @Test func flagOnMobileSourceWithoutAppAnswers503WithoutHandsTraffic() async throws {
        let capture = Capture()
        let accounts = accounts(baseURL: "https://hands.test")
        accounts.setHandsFeedbackUpstreamForTesting(fakeHands(capture))
        enableMultiApp(accounts)
        let token = token(accounts)
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
            func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
        }
        let log = Log()
        accounts.setHandsFeedbackWarningSinkForTesting { log.append($0) }

        try await withFeedbackApp(accounts: accounts) { client in
            let (body, contentType) = submitForm("ohos")
            var headers = authHeaders(token, kind: "ohos")
            headers[.contentType] = contentType
            let submitted = try await client.send(.post, headers: headers, to: URI(string: "/api/product-feedback")) { request in
                request.body = .init(string: body)
            }
            #expect(submitted.status == .serviceUnavailable)
            #expect(jsonBody(Data((submitted.body.string ?? "").utf8))["code"] as? String == "feedback_integration_unavailable")

            let listed = try await client.get(
                URI(string: "/api/product-feedback/tickets"),
                headers: authHeaders(token, kind: "ohos")
            )
            #expect(listed.status == .serviceUnavailable)
            #expect(jsonBody(Data((listed.body.string ?? "").utf8))["code"] as? String == "feedback_integration_unavailable")
        }
        #expect(capture.all().isEmpty, "no Hands traffic for an unconfigured source")
        #expect(log.all().filter { $0.contains("source unavailable") } == [
            "[product-feedback] source unavailable (ohos: source_entry_missing)",
            "[product-feedback] source unavailable (ohos: source_entry_missing)",
        ])
    }

    // MARK: - 3

    @Test func flagOnRouteBindingFailureAnswers503AndLogsItsReason() async throws {
        let capture = Capture()
        let accounts = accounts(baseURL: "https://hands.test")
        accounts.setHandsFeedbackUpstreamForTesting(fakeHands(capture))
        enableMultiApp(accounts)
        let badRoot = String(repeating: "ab", count: 32)
        accounts.setHandsFeedbackAppsForTesting(appsJSON(rootBytes: Array(repeating: 0, count: 32)).replacingOccurrences(
            of: base64url(Array(repeating: 0, count: 32)),
            with: badRoot
        ))
        let token = token(accounts)
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
            func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
        }
        let log = Log()
        accounts.setHandsFeedbackWarningSinkForTesting { log.append($0) }

        try await withFeedbackApp(accounts: accounts) { client in
            let listed = try await client.get(
                URI(string: "/api/product-feedback/tickets"),
                headers: authHeaders(token, kind: "android")
            )
            #expect(listed.status == .serviceUnavailable)
            #expect(listed.headers[HTTPField.Name("Retry-After")!] == "5")
            #expect(jsonBody(Data((listed.body.string ?? "").utf8))["code"] as? String == "feedback_integration_unavailable")
        }
        #expect(capture.all().isEmpty, "route binding fails before any Hands traffic")
        let lines = log.all().filter { $0.contains("[product-feedback]") }
        #expect(lines == ["[product-feedback] route binding failed (root_invalid)"])
        for secret in [badRoot, "android_token", "qk_android", "multi-reporter-secret", "multi-cursor-secret"] {
            #expect(!lines.contains { $0.contains(secret) })
        }
    }

    // MARK: - 4

    @Test func flagOffKeepsLegacyWebAppAndFlagOnWebFallsBackToLegacy() async throws {
        let capture = Capture()
        let accounts = accounts(baseURL: "https://hands.test")
        accounts.setHandsFeedbackUpstreamForTesting(fakeHands(capture))
        let token = token(accounts)

        try await withFeedbackApp(accounts: accounts) { client in
            let flagOff = try await client.get(
                URI(string: "/api/product-feedback/tickets"),
                headers: authHeaders(token, kind: "android")
            )
            #expect(flagOff.status == .ok)
            let flagOffList = try #require(listPath(capture.all()))
            #expect(flagOffList.path.hasPrefix("/api/apps/\(Self.legacyAppId)/reporter-feedback"))

            enableMultiApp(accounts)
            accounts.resetProductFeedbackRouteBindingCacheForTesting()
            let web = try await client.get(
                URI(string: "/api/product-feedback/tickets"),
                headers: authHeaders(token)
            )
            #expect(web.status == .ok)
            let webList = try #require(listPath(capture.all()))
            #expect(webList.path.hasPrefix("/api/apps/\(Self.legacyAppId)/reporter-feedback"))
        }
    }

    // MARK: - 5

    @Test func unknownClientKindOnConversationRequestIsInvalid() async throws {
        let capture = Capture()
        let accounts = accounts(baseURL: "https://hands.test")
        accounts.setHandsFeedbackUpstreamForTesting(fakeHands(capture))
        let token = token(accounts)

        try await withFeedbackApp(accounts: accounts) { client in
            let response = try await client.get(
                URI(string: "/api/product-feedback/tickets"),
                headers: authHeaders(token, kind: "symbian")
            )
            #expect(response.status == .badRequest)
            #expect(jsonBody(Data((response.body.string ?? "").utf8))["code"] as? String == "feedback_invalid")
        }
        #expect(capture.all().isEmpty)
    }

    // MARK: - 6

    @Test func androidTicketIsNotFoundFromAnyOtherSourceOnEveryEndpoint() async throws {
        let capture = Capture()
        let accounts = accounts(baseURL: "https://hands.test")
        accounts.setHandsFeedbackUpstreamForTesting(fakeHands(capture))
        enableMultiApp(accounts)
        let token = token(accounts)

        try await withFeedbackApp(accounts: accounts) { client in
            for clientKind in ["ios", "web"] {
                let before = capture.all().count
                let expectedAppId = clientKind == "ios" ? Self.iosAppId : Self.legacyAppId
                let commentBody = multipart([
                    "body": "reply from the wrong source",
                    "submission_id": "44444444-4444-4444-8444-444444444444",
                ])
                var commentHeaders = authHeaders(token, kind: clientKind)
                commentHeaders[.contentType] = commentBody.1
                var closeHeaders = authHeaders(token, kind: clientKind)
                closeHeaders[.contentType] = "application/json"

                let detail = try await client.get(
                    URI(string: "/api/product-feedback/tickets/\(Self.androidTicketId)"),
                    headers: authHeaders(token, kind: clientKind)
                )
                let comment = try await client.send(
                    .post,
                    headers: commentHeaders,
                    to: URI(string: "/api/product-feedback/tickets/\(Self.androidTicketId)/comments")
                ) { request in
                    request.body = .init(string: commentBody.0)
                }
                let close = try await client.send(
                    .post,
                    headers: closeHeaders,
                    to: URI(string: "/api/product-feedback/tickets/\(Self.androidTicketId)/close")
                ) { request in
                    request.body = .init(string: "{\"reason\":\"completed\"}")
                }
                let attachment = try await client.get(
                    URI(string: "/api/product-feedback/tickets/\(Self.androidTicketId)/attachments/55555555-5555-4555-8555-555555555555"),
                    headers: authHeaders(token, kind: clientKind)
                )
                for response in [detail, comment, close, attachment] {
                    #expect(response.status == .notFound)
                    #expect(jsonBody(Data((response.body.string ?? "").utf8))["code"] as? String == "feedback_not_found")
                }
                let ticketRequests = capture.all().dropFirst(before).filter { $0.url.contains(Self.androidTicketId) }
                #expect(ticketRequests.count == 4, "\(clientKind): each endpoint asked its own app once")
                for request in ticketRequests {
                    #expect(request.path.hasPrefix("/api/apps/\(expectedAppId)/"), "\(clientKind) must stay in its app: \(request.url)")
                }
            }
        }
        #expect(!capture.all().contains { $0.url.hasPrefix("/api/apps/\(Self.androidAppId)/reporter-feedback/\(Self.androidTicketId)") })
    }

    // MARK: - 7

    @Test func androidListCursorDoesNotReplayOnIOS() async throws {
        let capture = Capture()
        let accounts = accounts(baseURL: "https://hands.test")
        accounts.setHandsFeedbackUpstreamForTesting(fakeHands(capture))
        enableMultiApp(accounts)
        let token = token(accounts)

        try await withFeedbackApp(accounts: accounts) { client in
            let androidList = try await client.get(
                URI(string: "/api/product-feedback/tickets"),
                headers: authHeaders(token, kind: "android")
            )
            #expect(androidList.status == .ok)
            let cursor = try #require(jsonBody(Data((androidList.body.string ?? "").utf8))["next_cursor"] as? String)
            #expect(!cursor.isEmpty)

            let encoded = cursor.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? cursor
            let androidPage = try await client.get(
                URI(string: "/api/product-feedback/tickets?cursor=\(encoded)"),
                headers: authHeaders(token, kind: "android")
            )
            #expect(androidPage.status == .ok, "the cursor works on its own source")

            let listsBefore = capture.all().filter { $0.method == "GET" }.count
            let iosReplay = try await client.get(
                URI(string: "/api/product-feedback/tickets?cursor=\(encoded)"),
                headers: authHeaders(token, kind: "ios")
            )
            #expect(iosReplay.status == .badRequest)
            #expect(jsonBody(Data((iosReplay.body.string ?? "").utf8))["code"] as? String == "feedback_invalid")
            #expect(capture.all().filter { $0.method == "GET" }.count == listsBefore, "the replay never reaches Hands")
        }
    }
}
