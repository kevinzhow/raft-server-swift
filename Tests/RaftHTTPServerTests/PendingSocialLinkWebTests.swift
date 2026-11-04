import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func providerProfile(_ sub: String, _ email: String, verified: Bool = true) -> MobileProviderProfile {
    MobileProviderProfile(providerUserId: sub, email: email, displayName: "Provider Person", emailVerified: verified)
}

@Test func webConflictCreatesAPendingLinkThatPasswordLoginCompletesOnce() async throws {
    let accounts = EmailLoginDirectory()
    let existingId = "11111111-1111-4111-8111-000001084001"
    accounts.addAccount(id: existingId, email: "existing@web-link.test", password: "password123")
    accounts.markEmailVerified(userId: existingId)
    accounts.markPasswordCredentialEstablished(userId: existingId)
    accounts.appURL = "http://app.web-link.test"
    accounts.configuredSocialAuthProviders = ["google"]
    accounts.webProviderProfile = providerProfile("google-sub-web", "existing@web-link.test")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            func startState(_ path: String) async throws -> (state: String, cookie: String, response: ClientResponse) {
                let response = try await client.get(URI(string: path))
                let location = response.headers[.location] ?? ""
                let state = URLComponents(string: location)?.queryItems?.first { $0.name == "state" }?.value ?? ""
                let cookie = (response.headers[.setCookie] ?? "").split(separator: ";").first.map(String.init) ?? ""
                return (state, cookie, response)
            }
            func formPost(_ path: String, _ body: String, _ cookie: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.contentType] = "application/x-www-form-urlencoded"
                if !cookie.isEmpty { headers[.cookie] = cookie }
                return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
            }
            let started = try await startState("/api/auth/google/start?linkOnConflict=1&returnTo=%2Fs%2Fhome")
            #expect(started.response.status == .found)
            let callback = try await formPost("/api/auth/google/callback",
                                              "code=provider-code&state=\(started.state)", started.cookie)
            #expect(callback.status == .found)
            let redirect = URLComponents(string: callback.headers[.location] ?? "")
            #expect(redirect?.queryItems?.first { $0.name == "error" }?.value == nil)
            let code = try #require(redirect?.queryItems?.first { $0.name == "code" }?.value)
            let completionUserId = accounts.socialCompletionUserIdForTesting(provider: "google", code: code)
            #expect(completionUserId != nil, "the conflict completion exists")
            if let completionUserId { #expect(completionUserId == nil, "an older server cannot sign this completion in") }
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let complete = try await client.send(.post, headers: headers, to: "/api/auth/google/complete") { request in
                request.body = .init(string: "{\"code\":\"\(code)\"}")
            }
            #expect(complete.status == .conflict)
            let body = try JSONSerialization.jsonObject(with: Data((complete.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(body["code"] as? String == "account_link_required")
            #expect(body["provider"] as? String == "google")
            #expect(body["email"] as? String == "existing@web-link.test")
            #expect(body["returnTo"] as? String == "/s/home")
            let methods = body["signInMethods"] as? [String: Any]
            #expect(methods?["password"] as? Bool == true)
            #expect((methods?["providers"] as? [String])?.isEmpty == true)
            let token = try #require(body["pendingLinkToken"] as? String)
            #expect(token.count >= 32)
            #expect(accounts.sessionCount == 0)
            #expect(accounts.linkedProviderUserIds(userId: existingId, provider: "google").isEmpty)
        }
    }
}

@Test func webConflictWithoutOptInKeepsTheErrorRedirect() async throws {
    let accounts = EmailLoginDirectory()
    let existingId = "11111111-1111-4111-8111-000001084011"
    accounts.addAccount(id: existingId, email: "existing@web-link2.test", password: "password123")
    accounts.markEmailVerified(userId: existingId)
    accounts.appURL = "http://app.web-link2.test"
    accounts.configuredSocialAuthProviders = ["google"]
    accounts.webProviderProfile = providerProfile("google-sub-web2", "existing@web-link2.test")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            func startState(_ path: String) async throws -> (state: String, cookie: String, response: ClientResponse) {
                let response = try await client.get(URI(string: path))
                let location = response.headers[.location] ?? ""
                let state = URLComponents(string: location)?.queryItems?.first { $0.name == "state" }?.value ?? ""
                let cookie = (response.headers[.setCookie] ?? "").split(separator: ";").first.map(String.init) ?? ""
                return (state, cookie, response)
            }
            func formPost(_ path: String, _ body: String, _ cookie: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.contentType] = "application/x-www-form-urlencoded"
                if !cookie.isEmpty { headers[.cookie] = cookie }
                return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
            }
            let started = try await startState("/api/auth/google/start")
            let callback = try await formPost("/api/auth/google/callback",
                                              "code=provider-code&state=\(started.state)", started.cookie)
            #expect(callback.status == .found)
            let redirect = URLComponents(string: callback.headers[.location] ?? "")
            #expect(redirect?.queryItems?.first { $0.name == "code" }?.value == nil)
            let error = redirect?.queryItems?.first { $0.name == "error" }?.value ?? ""
            #expect(error.contains("already exists"))
        }
    }
}

@Test func anotherLinkedProviderCompletesThePendingGoogleLink() async throws {
    let accounts = EmailLoginDirectory()
    let existingId = "11111111-1111-4111-8111-000001084021"
    accounts.addAccount(id: existingId, email: "existing@web-link3.test", password: "password123")
    accounts.markEmailVerified(userId: existingId)
    accounts.markPasswordCredentialEstablished(userId: existingId)
    accounts.linkIdentityForTesting(userId: existingId, provider: "github", providerUserId: "1304", providerEmail: "existing@web-link3.test")
    accounts.appURL = "http://app.web-link3.test"
    accounts.configuredSocialAuthProviders = ["google", "github"]

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            func startState(_ path: String) async throws -> (state: String, cookie: String, response: ClientResponse) {
                let response = try await client.get(URI(string: path))
                let location = response.headers[.location] ?? ""
                let state = URLComponents(string: location)?.queryItems?.first { $0.name == "state" }?.value ?? ""
                let cookie = (response.headers[.setCookie] ?? "").split(separator: ";").first.map(String.init) ?? ""
                return (state, cookie, response)
            }
            func formPost(_ path: String, _ body: String, _ cookie: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.contentType] = "application/x-www-form-urlencoded"
                if !cookie.isEmpty { headers[.cookie] = cookie }
                return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
            }
            func roundTrip(_ provider: String, _ sub: String, _ linkOnConflict: Bool) async throws -> String? {
                accounts.webProviderProfile = providerProfile(sub, "existing@web-link3.test")
                let path = "/api/auth/\(provider)/start" + (linkOnConflict ? "?linkOnConflict=1" : "")
                let started = try await startState(path)
                let callback = try await formPost("/api/auth/\(provider)/callback",
                                                  "code=provider-code&state=\(started.state)", started.cookie)
                #expect(callback.status == .found)
                return URLComponents(string: callback.headers[.location] ?? "")?.queryItems?.first { $0.name == "code" }?.value
            }
            let googleCode = try #require(try await roundTrip("google", "google-sub-web3", true))
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let complete = try await client.send(.post, headers: headers, to: "/api/auth/google/complete") { request in
                request.body = .init(string: "{\"code\":\"\(googleCode)\"}")
            }
            #expect(complete.status == .conflict)
            let body = try JSONSerialization.jsonObject(with: Data((complete.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let pendingToken = try #require(body["pendingLinkToken"] as? String)
            #expect((body["signInMethods"] as? [String: Any])?["providers"] as? [String] == ["github"])

            let githubCode = try #require(try await roundTrip("github", "1304", false))
            let githubComplete = try await client.send(.post, headers: headers, to: "/api/auth/github/complete") { request in
                request.body = .init(string: "{\"code\":\"\(githubCode)\",\"pendingLinkToken\":\"\(pendingToken)\"}")
            }
            #expect(githubComplete.status == .ok)
            let linked = try JSONSerialization.jsonObject(with: Data((githubComplete.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(linked["accessToken"] as? String != nil)
            #expect(linked["linkedProvider"] as? String == "google")
            #expect(accounts.linkedProviderUserIds(userId: existingId, provider: "google") == ["google-sub-web3"])
        }
    }
}
