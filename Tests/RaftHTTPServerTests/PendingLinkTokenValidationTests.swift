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

/// Pinned `routes/auth.ts:1131-1138` checks the completion code before
/// `parsePendingLinkToken` on `/:provider/complete`, so a malformed token
/// cannot preempt the published "code is required" 400. Mobile completion
/// (`routes/auth.ts:887-889`) parses the token first and keeps that order.
@Test func providerCompletionChecksTheCodeBeforeParsingPendingLinkToken() async throws {
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
            let codeRequired = #"{"error":"Sign-in completion code is required"}"#
            let mustBeString = #"{"code":"pending_link_token_invalid","error":"pendingLinkToken must be a string"}"#
            let invalidCompletion = #"{"error":"Invalid or expired social auth completion"}"#

            // `!code` in JavaScript covers a missing member, `null`, `""`,
            // `0` and `false`; each one now answers before the token 400.
            let tooLong = String(repeating: "y", count: 257)
            let falsyBodies = [
                #"{"pendingLinkToken":5}"#,
                #"{"pendingLinkToken":"\#(tooLong)"}"#,
                #"{"code":null,"pendingLinkToken":5}"#,
                #"{"code":"","pendingLinkToken":5}"#,
                #"{"code":0,"pendingLinkToken":5}"#,
                #"{"code":false,"pendingLinkToken":5}"#,
            ]
            for provider in ["google", "github"] {
                for body in falsyBodies {
                    let response = try await post("/api/auth/\(provider)/complete", body)
                    #expect(response.status == .badRequest)
                    #expect(response.body.string == codeRequired)
                }
            }

            // Whitespace is truthy upstream, so it passes the code check and
            // the token 400 is the next refusal.
            let spaceToken = try await post(
                "/api/auth/google/complete",
                #"{"code":" ","pendingLinkToken":5}"#
            )
            #expect(spaceToken.status == .badRequest)
            #expect(spaceToken.body.string == mustBeString)

            let tabToken = try await post(
                "/api/auth/github/complete",
                #"{"code":"\t","pendingLinkToken":5}"#
            )
            #expect(tabToken.status == .badRequest)
            #expect(tabToken.body.string == mustBeString)

            // Whitespace without a token reaches the completion lookup.
            let space = try await post("/api/auth/google/complete", #"{"code":" "}"#)
            #expect(space.status == .badRequest)
            #expect(space.body.string == invalidCompletion)

            let tab = try await post("/api/auth/google/complete", #"{"code":"\t"}"#)
            #expect(tab.status == .badRequest)
            #expect(tab.body.string == invalidCompletion)

            // Mobile keeps the pinned token-first order.
            let mobile = try await post(
                "/api/auth/mobile/oauth/complete",
                #"{"pendingLinkToken":5}"#
            )
            #expect(mobile.status == .badRequest)
            #expect(mobile.body.string == mustBeString)

            // Provider resolution still precedes the body checks: the unknown
            // provider keeps the 404 fallthrough even with a malformed token.
            let unknown = try await post(
                "/api/auth/mastodon/complete",
                #"{"code":"c","pendingLinkToken":5}"#
            )
            #expect(unknown.status == .notFound)
        }
    }
}

/// Pinned `routes/auth.ts:1131-1138` applies the raw JavaScript `!code` check,
/// not a string type test. `5`, `true`, `[]` and `{}` are truthy, so with a
/// malformed `pendingLinkToken` the next refusal is the token 400; `0`, `-0`,
/// `false`, `null`, a missing member and `""` are falsy and keep the
/// "code is required" 400. Whitespace is a non-empty string (truthy) and also
/// reaches the token check.
@Test func providerCompletionUsesJavaScriptCodeTruthinessBeforeThePendingLinkToken() async throws {
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
            let codeRequired = #"{"error":"Sign-in completion code is required"}"#
            let mustBeString = #"{"code":"pending_link_token_invalid","error":"pendingLinkToken must be a string"}"#
            let cases: [(String, String)] = [
                (#"{"code":5,"pendingLinkToken":5}"#, mustBeString),
                (#"{"code":true,"pendingLinkToken":5}"#, mustBeString),
                (#"{"code":[],"pendingLinkToken":5}"#, mustBeString),
                (#"{"code":{},"pendingLinkToken":5}"#, mustBeString),
                (#"{"code":0,"pendingLinkToken":5}"#, codeRequired),
                (#"{"code":-0,"pendingLinkToken":5}"#, codeRequired),
                (#"{"code":false,"pendingLinkToken":5}"#, codeRequired),
                (#"{"code":null,"pendingLinkToken":5}"#, codeRequired),
                (#"{"pendingLinkToken":5}"#, codeRequired),
                (#"{"code":"","pendingLinkToken":5}"#, codeRequired),
                (#"{"code":" ","pendingLinkToken":5}"#, mustBeString),
                (#"{"code":"\t","pendingLinkToken":5}"#, mustBeString),
            ]
            for provider in ["google", "github"] {
                for (body, expected) in cases {
                    let response = try await post("/api/auth/\(provider)/complete", body)
                    #expect(response.status == .badRequest, "\(provider) \(body)")
                    #expect(response.body.string == expected, "\(provider) \(body)")
                }
            }
        }
    }
}

/// Pinned `services/socialAuthService.ts:203` `hashValue` calls
/// `createHash("sha256").update(value)`; a truthy non-string completion code
/// passes `!code` but makes that call throw `TypeError`. The route catch
/// (`routes/auth.ts:1228-1241`) does not match its `Invalid`/`expired`/
/// `mismatch` branch, so `sendJsonServerError` (`errorResponse.ts:138-197`)
/// answers 500 `{"error":"Failed to complete sign-in","correlationId":"…"}`
/// with the same id in `X-Slock-Error-Id`. The pending-link token is parsed
/// first but a valid or absent token cannot change that lookup.
@Test func providerCompletionServerErrorForTruthyNonStringCode() async throws {
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
            let prefix = #"{"error":"Failed to complete sign-in","correlationId":""#
            let bodies = [
                #"{"code":5}"#,
                #"{"code":true}"#,
                #"{"code":[]}"#,
                #"{"code":{}}"#,
                #"{"code":5,"pendingLinkToken":"unknown-token"}"#,
            ]
            for body in bodies {
                let response = try await post("/api/auth/google/complete", body)
                #expect(response.status == .internalServerError, "\(body)")
                let text = response.body.string ?? ""
                #expect(text.hasPrefix(prefix), "\(body) -> \(text)")
                #expect(text.hasSuffix("\"}"), "\(body) -> \(text)")
                let correlation = String(text.dropFirst(prefix.count).dropLast(2))
                #expect(correlation.count == 36, "\(body) -> \(text)")
                #expect(UUID(uuidString: correlation)?.uuidString.lowercased() == correlation)
                #expect(response.headers[HTTPField.Name("X-Slock-Error-Id")!] == correlation)
            }
        }
    }
}
