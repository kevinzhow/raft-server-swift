import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private let appLoginReturnUri = "raft://login/callback"

private struct AppLoginFixture {
    let accounts: EmailLoginDirectory
    let userId: String
    let bearer: String
}

private func makeAppLoginFixture(_ suffix: String) -> AppLoginFixture {
    let accounts = EmailLoginDirectory()
    accounts.appURL = "https://app.raft.test"
    let userId = "11111111-1111-4111-8111-000001038\(suffix)"
    let email = "app-login-\(suffix)@slock.test"
    accounts.addAccount(id: userId, email: email, password: "password123")
    accounts.markEmailVerified(userId: userId)
    return AppLoginFixture(accounts: accounts, userId: userId, bearer: accounts.mintAccessTokenForTesting(userId: userId))
}

private func appLoginBody(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func jsonHeaders(_ bearer: String? = nil) -> HTTPFields {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let bearer { headers[.authorization] = "Bearer \(bearer)" }
    return headers
}

private func pkcePair() -> (verifier: String, challenge: String) {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
    let verifier = base64url(Data(bytes))
    let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    return (verifier, challenge)
}

private func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func startAppLogin(
    _ client: any Client,
    returnUri: String = appLoginReturnUri,
    challenge: String,
    extra: [String: Any] = [:]
) async throws -> ClientResponse {
    var payload: [String: Any] = ["returnUri": returnUri, "codeChallenge": challenge]
    for (key, value) in extra { payload[key] = value }
    let body = try JSONSerialization.data(withJSONObject: payload)
    return try await client.send(.post, headers: jsonHeaders(), to: "/api/auth/app-login/start") { request in
        request.body = .init(data: body)
    }
}

@Test func appLoginStartApproveAndCompleteIssuesAWorkingSession() async throws {
    let fixture = makeAppLoginFixture("001")
    let pair = pkcePair()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let started = try await startAppLogin(client, challenge: pair.challenge)
            #expect(started.status == .created)
            let startBody = try appLoginBody(started)
            let requestId = try #require(startBody["requestId"] as? String)
            #expect(startBody["loginUrl"] as? String == "https://app.raft.test/login/app?request=\(requestId)")

            let anonymous = try await client.get(URI(string: "/api/auth/app-login/requests/\(requestId)"))
            #expect(anonymous.status == .unauthorized)

            let described = try await client.get(
                URI(string: "/api/auth/app-login/requests/\(requestId)"),
                headers: jsonHeaders(fixture.bearer)
            )
            #expect(described.status == .ok)

            let approved = try await client.send(
                .post,
                headers: jsonHeaders(fixture.bearer),
                to: URI(string: "/api/auth/app-login/requests/\(requestId)/approve")
            )
            #expect(approved.status == .ok)
            let redirectUrl = try #require(try appLoginBody(approved)["redirectUrl"] as? String)
            let callback = try #require(URLComponents(string: redirectUrl))
            #expect("\(callback.scheme ?? "")://\(callback.host ?? "")\(callback.path)" == appLoginReturnUri)
            #expect(callback.queryItems?.map(\.name) == ["requestId", "code"])
            #expect(callback.queryItems?.first(where: { $0.name == "requestId" })?.value == requestId)
            let code = try #require(callback.queryItems?.first(where: { $0.name == "code" })?.value)

            let again = try await client.send(
                .post,
                headers: jsonHeaders(fixture.bearer),
                to: URI(string: "/api/auth/app-login/requests/\(requestId)/approve")
            )
            #expect(again.status == .conflict)

            let wrong = try await client.send(.post, headers: jsonHeaders(), to: "/api/auth/app-login/complete") { request in
                request.body = .init(string: "{\"code\":\"\(code)\",\"codeVerifier\":\"\(pkcePair().verifier)\"}")
            }
            #expect(wrong.status == .badRequest)
            #expect(try appLoginBody(wrong)["code"] as? String == "pkce_mismatch")

            let completed = try await client.send(.post, headers: jsonHeaders(), to: "/api/auth/app-login/complete") { request in
                request.body = .init(string: "{\"code\":\"\(code)\",\"codeVerifier\":\"\(pair.verifier)\"}")
            }
            #expect(completed.status == .ok)
            let session = try appLoginBody(completed)
            #expect((session["user"] as? [String: Any])?["id"] as? String == fixture.userId)
            let accessToken = try #require(session["accessToken"] as? String)
            #expect(session["refreshToken"] is String)

            let me = try await client.get(URI(string: "/api/auth/me"), headers: jsonHeaders(accessToken))
            #expect(me.status == .ok)

            let replay = try await client.send(.post, headers: jsonHeaders(), to: "/api/auth/app-login/complete") { request in
                request.body = .init(string: "{\"code\":\"\(code)\",\"codeVerifier\":\"\(pair.verifier)\"}")
            }
            #expect(replay.status == .gone)
            #expect(try appLoginBody(replay)["code"] as? String == "code_consumed")
        }
    }
}

@Test func appLoginStartOnlyAllowsShippedReturnUrisAndS256Challenges() async throws {
    let fixture = makeAppLoginFixture("002")
    let pair = pkcePair()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            for returnUri in ["raft://oauth/callback", "https://evil.test/cb", "raft://login/callback/extra"] {
                let response = try await startAppLogin(client, returnUri: returnUri, challenge: pair.challenge)
                #expect(response.status == .badRequest, "\(returnUri)")
                #expect(try appLoginBody(response)["code"] as? String == "return_uri_not_allowed")
            }

            let debug = try await startAppLogin(
                client,
                returnUri: "raft-debug://login/callback",
                challenge: pair.challenge,
                extra: ["codeChallengeMethod": "S256", "platform": "ohos", "appEnv": "staging"]
            )
            #expect(debug.status == .created)

            let plainMethod = try await startAppLogin(
                client,
                challenge: pair.challenge,
                extra: ["codeChallengeMethod": "plain"]
            )
            #expect(plainMethod.status == .badRequest)

            let short = try await startAppLogin(client, challenge: "short")
            #expect(short.status == .badRequest)
            #expect(try appLoginBody(short)["code"] as? String == "code_challenge_invalid")
        }
    }
}

@Test func appLoginDenyAndExpiryReturnTheAppError() async throws {
    let fixture = makeAppLoginFixture("003")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let denied = try await startAppLogin(client, challenge: pkcePair().challenge)
            let deniedId = try #require(try appLoginBody(denied)["requestId"] as? String)
            let denyResponse = try await client.send(
                .post,
                headers: jsonHeaders(fixture.bearer),
                to: URI(string: "/api/auth/app-login/requests/\(deniedId)/deny")
            )
            #expect(denyResponse.status == .ok)
            #expect(try appLoginBody(denyResponse)["redirectUrl"] as? String == "\(appLoginReturnUri)?requestId=\(deniedId)&error=access_denied")

            let approveAfterDeny = try await client.send(
                .post,
                headers: jsonHeaders(fixture.bearer),
                to: URI(string: "/api/auth/app-login/requests/\(deniedId)/approve")
            )
            #expect(approveAfterDeny.status == .conflict)

            let expired = try await startAppLogin(client, challenge: pkcePair().challenge)
            let expiredId = try #require(try appLoginBody(expired)["requestId"] as? String)
            fixture.accounts.expireAppLoginRequestForTesting(requestId: expiredId)
            let approveExpired = try await client.send(
                .post,
                headers: jsonHeaders(fixture.bearer),
                to: URI(string: "/api/auth/app-login/requests/\(expiredId)/approve")
            )
            #expect(approveExpired.status == .gone)
            let expiredBody = try appLoginBody(approveExpired)
            #expect(expiredBody["code"] as? String == "request_expired")
            #expect(expiredBody["redirectUrl"] as? String == "\(appLoginReturnUri)?requestId=\(expiredId)&error=expired")

            let unknown = try await client.send(
                .post,
                headers: jsonHeaders(fixture.bearer),
                to: URI(string: "/api/auth/app-login/requests/\(UUID().uuidString.lowercased())/approve")
            )
            #expect(unknown.status == .notFound)
        }
    }
}

@Test func appLoginApprovedCodeExpiresWithItsRequest() async throws {
    let fixture = makeAppLoginFixture("004")
    let pair = pkcePair()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let started = try await startAppLogin(client, challenge: pair.challenge)
            let requestId = try #require(try appLoginBody(started)["requestId"] as? String)
            let approved = try await client.send(
                .post,
                headers: jsonHeaders(fixture.bearer),
                to: URI(string: "/api/auth/app-login/requests/\(requestId)/approve")
            )
            let redirectUrl = try #require(try appLoginBody(approved)["redirectUrl"] as? String)
            let code = try #require(URLComponents(string: redirectUrl)?.queryItems?.first(where: { $0.name == "code" })?.value)

            fixture.accounts.expireAppLoginRequestForTesting(requestId: requestId)
            let completed = try await client.send(.post, headers: jsonHeaders(), to: "/api/auth/app-login/complete") { request in
                request.body = .init(string: "{\"code\":\"\(code)\",\"codeVerifier\":\"\(pair.verifier)\"}")
            }
            #expect(completed.status == .gone)
            #expect(try appLoginBody(completed)["code"] as? String == "code_expired")
        }
    }
}
