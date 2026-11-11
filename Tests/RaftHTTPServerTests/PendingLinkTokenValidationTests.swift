import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Pinned `routes/auth.ts:168-177` `parsePendingLinkToken` runs on
/// `/mobile/oauth/complete`, `/:provider/complete`, `/login` and
/// `/pending-link/cancel`. This locks the three sites that previously ignored
/// the member, including the cancel route's "required" answer.
@Test func pendingLinkTokenIsValidatedOnEveryCompletionRoute() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func post(_ path: String, _ body: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: URI(string: path)) {
                    $0.body = .init(string: body)
                }
            }
            let mustBeString = #"{"code":"pending_link_token_invalid","error":"pendingLinkToken must be a string"}"#
            let required = #"{"code":"pending_link_token_invalid","error":"pendingLinkToken is required"}"#

            let mobile = try await post(
                "/api/auth/mobile/oauth/complete",
                #"{"code":"c","codeVerifier":"v","pendingLinkToken":5}"#
            )
            #expect(mobile.status == .badRequest)
            #expect(mobile.body.string == mustBeString)

            let web = try await post(
                "/api/auth/google/complete",
                #"{"code":"c","pendingLinkToken":["x"]}"#
            )
            #expect(web.status == .badRequest)
            #expect(web.body.string == mustBeString)

            let tooLong = String(repeating: "x", count: 257)
            let long = try await post(
                "/api/auth/mobile/oauth/complete",
                #"{"pendingLinkToken":"\#(tooLong)"}"#
            )
            #expect(long.status == .badRequest)
            #expect(long.body.string == mustBeString)

            let missing = try await post("/api/auth/pending-link/cancel", "{}")
            #expect(missing.status == .badRequest)
            #expect(missing.body.string == required)

            let empty = try await post("/api/auth/pending-link/cancel", #"{"pendingLinkToken":""}"#)
            #expect(empty.status == .badRequest)
            #expect(empty.body.string == required)

            let null = try await post("/api/auth/pending-link/cancel", #"{"pendingLinkToken":null}"#)
            #expect(null.status == .badRequest)
            #expect(null.body.string == required)

            let wrongType = try await post("/api/auth/pending-link/cancel", #"{"pendingLinkToken":false}"#)
            #expect(wrongType.status == .badRequest)
            #expect(wrongType.body.string == mustBeString)

            let cancel = try await post("/api/auth/pending-link/cancel", #"{"pendingLinkToken":"unknown-token"}"#)
            #expect(cancel.status == .noContent)

            let providerLong = String(repeating: "y", count: 257)
            let provider = try await post(
                "/api/auth/github/complete",
                #"{"code":"c","pendingLinkToken":"\#(providerLong)"}"#
            )
            #expect(provider.status == .badRequest)
            #expect(provider.body.string == mustBeString)
        }
    }
}
