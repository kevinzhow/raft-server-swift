import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func profile(_ sub: String, _ email: String) -> MobileProviderProfile {
    MobileProviderProfile(providerUserId: sub, email: email, displayName: "Mobile Person", emailVerified: true)
}

@Test func mobilePkceConflictAnswersAccountLinkRequiredAndPasswordCompletesIt() async throws {
    let accounts = EmailLoginDirectory()
    let existingId = "11111111-1111-4111-8111-000001085001"
    accounts.addAccount(id: existingId, email: "mobile@pending-link.test", password: "password123")
    accounts.markEmailVerified(userId: existingId)
    accounts.markPasswordCredentialEstablished(userId: existingId)
    accounts.configureAuthSimulationForTesting { $0.mobileProviderProfile = profile("google-sub-mobile", "mobile@pending-link.test") }
    let verifier = "pending-link-mobile-verifier-0123456789"
    let challenge = EmailLoginDirectory.pkceChallengeForTesting(verifier)
    let returnUri = "raft://oauth/callback"

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var jsonHeaders = HTTPFields()
            jsonHeaders[.contentType] = "application/json"
            func start(_ linkOnConflict: Bool) async throws -> (authorizationUrl: String, state: String) {
                let body = "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"\(returnUri)\",\"codeChallenge\":\"\(challenge)\"\(linkOnConflict ? ",\"linkOnConflict\":true" : "")}"
                let response = try await client.send(.post, headers: jsonHeaders, to: URI(string: "/api/auth/mobile/oauth/start")) { request in
                    request.body = .init(string: body)
                }
                #expect(response.status == .created)
                let parsed = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                let url = try #require(parsed["authorizationUrl"] as? String)
                let state = URLComponents(string: url)?.queryItems?.first { $0.name == "state" }?.value ?? ""
                return (url, state)
            }
            func mobileCallback(_ state: String) async throws -> (status: HTTPResponse.Status, location: String) {
                let encoded = state.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? state
                let response = try await client.get(URI(string: "/api/auth/google/callback?code=provider-code&state=\(encoded)"))
                return (response.status, response.headers[.location] ?? "")
            }
            func complete(_ code: String, _ verifier: String, _ token: String? = nil) async throws -> (HTTPResponse.Status, [String: Any]) {
                var payload: [String: Any] = ["code": code, "codeVerifier": verifier]
                if let token { payload["pendingLinkToken"] = token }
                let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                let response = try await client.send(.post, headers: jsonHeaders, to: URI(string: "/api/auth/mobile/oauth/complete")) { request in
                    request.body = .init(string: body)
                }
                return (response.status, (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let first = try await start(true)
            let firstCallback = try await mobileCallback(first.state)
            #expect(firstCallback.status == .found)
            let firstCode = URLComponents(string: firstCallback.location)?.queryItems?.first { $0.name == "code" }?.value ?? ""
            #expect((try await complete(firstCode, "wrong-verifier-0123456789012345")).0 == .badRequest)

            let second = try await start(true)
            let secondCallback = try await mobileCallback(second.state)
            let secondCode = URLComponents(string: secondCallback.location)?.queryItems?.first { $0.name == "code" }?.value ?? ""
            let conflict = try await complete(secondCode, verifier)
            #expect(conflict.0 == .conflict)
            #expect(conflict.1["code"] as? String == "account_link_required")
            #expect(conflict.1["email"] as? String == "mobile@pending-link.test")
            #expect(conflict.1["returnUri"] as? String == returnUri)
            #expect(accounts.sessionCount == 0)
            let replay = try await complete(secondCode, verifier)
            #expect(replay.0 != .ok)
            #expect(replay.0 != .conflict)

            let token = try #require(conflict.1["pendingLinkToken"] as? String)
            let login = try await client.send(.post, headers: jsonHeaders, to: URI(string: "/api/auth/login")) { request in
                request.body = .init(string: "{\"email\":\"mobile@pending-link.test\",\"password\":\"password123\",\"pendingLinkToken\":\"\(token)\"}")
            }
            #expect(login.status == .ok)
            let loginBody = try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(loginBody["linkedProvider"] as? String == "google")
            #expect(accounts.linkedProviderUserIds(userId: existingId, provider: "google") == ["google-sub-mobile"])
        }
    }
}

@Test func mobileConflictWithoutOptInReportsAccountConflict() async throws {
    let accounts = EmailLoginDirectory()
    let existingId = "11111111-1111-4111-8111-000001085011"
    accounts.addAccount(id: existingId, email: "mobile2@pending-link.test", password: "password123")
    accounts.markEmailVerified(userId: existingId)
    accounts.configureAuthSimulationForTesting { $0.mobileProviderProfile = profile("google-sub-mobile2", "mobile2@pending-link.test") }
    let challenge = EmailLoginDirectory.pkceChallengeForTesting("old-client-verifier-0123456789abc")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let startResponse = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/mobile/oauth/start")) { request in
                request.body = .init(string: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"raft://oauth/callback\",\"codeChallenge\":\"\(challenge)\"}")
            }
            #expect(startResponse.status == .created)
            let started = try JSONSerialization.jsonObject(with: Data((startResponse.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let url = try #require(started["authorizationUrl"] as? String)
            let state = try #require(URLComponents(string: url)?.queryItems?.first { $0.name == "state" }?.value)
            let encoded = state.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? state
            let callback = try await client.get(URI(string: "/api/auth/google/callback?code=provider-code&state=\(encoded)"))
            #expect(callback.status == .found)
            let returned = URLComponents(string: callback.headers[.location] ?? "")
            #expect(returned?.queryItems?.first { $0.name == "error" }?.value == "account_conflict")
            #expect(returned?.queryItems?.first { $0.name == "code" }?.value == nil)
        }
    }
}

@Test func mobileAnotherLinkedProviderCompletesThePendingGoogleLink() async throws {
    let accounts = EmailLoginDirectory()
    let existingId = "11111111-1111-4111-8111-000001085021"
    accounts.addAccount(id: existingId, email: "mobile3@pending-link.test", password: "password123")
    accounts.markEmailVerified(userId: existingId)
    accounts.markPasswordCredentialEstablished(userId: existingId)
    accounts.linkIdentityForTesting(userId: existingId, provider: "github", providerUserId: "1304", providerEmail: "mobile3@pending-link.test")
    let verifier = "pending-link-mobile-provider-verifier-0123"
    let challenge = EmailLoginDirectory.pkceChallengeForTesting(verifier)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            func roundTrip(_ provider: String, _ sub: String) async throws -> String {
                accounts.configureAuthSimulationForTesting { $0.mobileProviderProfile = profile(sub, "mobile3@pending-link.test") }
                let startResponse = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/mobile/oauth/start")) { request in
                    request.body = .init(string: "{\"provider\":\"\(provider)\",\"mode\":\"login\",\"returnUri\":\"raft://oauth/callback\",\"codeChallenge\":\"\(challenge)\",\"linkOnConflict\":true}")
                }
                #expect(startResponse.status == .created)
                let started = try JSONSerialization.jsonObject(with: Data((startResponse.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                let url = try #require(started["authorizationUrl"] as? String)
                let state = try #require(URLComponents(string: url)?.queryItems?.first { $0.name == "state" }?.value)
                let encoded = state.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? state
                let callback = try await client.get(URI(string: "/api/auth/\(provider)/callback?code=provider-code&state=\(encoded)"))
                #expect(callback.status == .found)
                return try #require(URLComponents(string: callback.headers[.location] ?? "")?.queryItems?.first { $0.name == "code" }?.value)
            }
            func complete(_ code: String, _ token: String? = nil) async throws -> (HTTPResponse.Status, [String: Any]) {
                var payload: [String: Any] = ["code": code, "codeVerifier": verifier]
                if let token { payload["pendingLinkToken"] = token }
                let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/mobile/oauth/complete")) { request in
                    request.body = .init(string: body)
                }
                return (response.status, (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let conflict = try await complete(try await roundTrip("google", "google-sub-mobile3"))
            #expect(conflict.0 == .conflict)
            #expect((conflict.1["signInMethods"] as? [String: Any])?["providers"] as? [String] == ["github"])
            let token = try #require(conflict.1["pendingLinkToken"] as? String)
            let completeWithGithub = try await complete(try await roundTrip("github", "1304"), token)
            #expect(completeWithGithub.0 == .ok)
            #expect((completeWithGithub.1["user"] as? [String: Any])?["id"] as? String == existingId)
            #expect(completeWithGithub.1["accessToken"] as? String != nil)
            #expect(completeWithGithub.1["linkedProvider"] as? String == "google")
            #expect(accounts.linkedProviderUserIds(userId: existingId, provider: "google") == ["google-sub-mobile3"])
        }
    }
}

@Test func aPasswordChangedBeforeTheLinkIsCheckedLinksNothingAndSpendsNoToken() async throws {
    let accounts = EmailLoginDirectory()
    let existingId = "11111111-1111-4111-8111-000001085041"
    accounts.addAccount(id: existingId, email: "stale@pending-link.test", password: "password123")
    accounts.markEmailVerified(userId: existingId)
    accounts.markPasswordCredentialEstablished(userId: existingId)
    let token = accounts.issuePendingSocialLinkForTesting(
        provider: "google", providerUserId: "google-sub-stale", email: "stale@pending-link.test"
    )
    accounts.setPasswordForTesting(userId: existingId, password: "changed-password")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            func login(_ password: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/login")) { request in
                    request.body = .init(string: "{\"email\":\"stale@pending-link.test\",\"password\":\"\(password)\",\"pendingLinkToken\":\"\(token)\"}")
                }
                return (response.status, (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let stale = try await login("password123")
            #expect(stale.0 == .unauthorized)
            #expect(stale.1["code"] as? String == "AUTH_INVALID_CREDENTIALS")
            #expect(accounts.sessionCount == 0)
            #expect(accounts.linkedProviderUserIds(userId: existingId, provider: "google").isEmpty)
            let current = try await login("changed-password")
            #expect(current.0 == .ok)
            #expect(accounts.linkedProviderUserIds(userId: existingId, provider: "google") == ["google-sub-stale"])
        }
    }
}
