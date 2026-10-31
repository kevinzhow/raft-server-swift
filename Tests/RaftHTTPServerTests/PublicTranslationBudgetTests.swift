import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func publicTranslationStopsAfterOneHundredTwentyRequestsPerMinute() async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: EmailLoginDirectory()
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            for index in 0..<120 {
                let response = try await client.send(.post, headers: headers, to: "/api/public/servers/rate-limit-probe/message-translations:batch") { request in
                    request.body = .init(string: "{}")
                }
                #expect(response.status == .badRequest, "request \(index + 1) should reach validation")
            }
            let limited = try await client.send(.post, headers: headers, to: "/api/public/servers/rate-limit-probe/message-translations:batch") { request in
                request.body = .init(string: "{}")
            }
            #expect(limited.status == .tooManyRequests)
            let body = try JSONSerialization.jsonObject(with: Data((limited.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["error"] as? String == "Too many public translation requests, please slow down")
        }
    }
}
