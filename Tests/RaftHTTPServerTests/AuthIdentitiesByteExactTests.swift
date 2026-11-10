import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Locks the bytes and header set of the identity/login/app-login/profile
/// routes after they moved behind `AuthIdentitiesService` and `respond`.

private let standardHeaders = ["X-Robots-Tag", "Content-Type"]

private func byteFixture() -> (accounts: EmailLoginDirectory, userId: String, bearer: String) {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    let userId = "11111111-1111-4111-8111-000002100001"
    accounts.addAccount(id: userId, email: "bytes@slock.test", password: "password123", passwordCredentialEstablished: false)
    accounts.addAuthIdentityForTesting(userId: userId, provider: "github", providerEmail: "gh@example.com")
    return (accounts, userId, accounts.mintAccessTokenForTesting(userId: userId))
}

private func send(
    _ client: any Client,
    _ method: HTTPRequest.Method,
    _ path: String,
    bearer: String? = nil,
    contentType: String? = "application/json",
    body: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    if let contentType { headers[.contentType] = contentType }
    if let bearer { headers[.authorization] = "Bearer \(bearer)" }
    return try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
}

private func expectStandard(_ response: ClientResponse, length: Int) {
    #expect(response.headers[HTTPField.Name("Content-Type")!] == "application/json; charset=utf-8")
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] != nil)
    #expect(response.headers[HTTPField.Name("Content-Length")!] == String(length))
    #expect(response.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
}

@Test func authIdentityRoutesPublishTheLegacyBytesAndHeaders() async throws {
    let fixture = byteFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let unauthorized = try await send(client, .get, "/api/auth/identities")
            #expect(unauthorized.status == .unauthorized)
            #expect(unauthorized.body.string == #"{"error":"Unauthorized"}"#)
            expectStandard(unauthorized, length: 24)

            let listed = try await send(client, .get, "/api/auth/identities", bearer: fixture.bearer)
            let expected = #"{"identities":[{"provider":"github","providerEmail":"gh@example.com"}],"passwordConfigured":false}"#
            #expect(listed.status == .ok)
            #expect(listed.body.string == expected)
            expectStandard(listed, length: expected.utf8.count)

            let blocked = try await send(client, .delete, "/api/auth/identities/github", bearer: fixture.bearer)
            #expect(blocked.status == .conflict)
            #expect(blocked.body.string == #"{"code":"PASSWORD_CREDENTIAL_REQUIRED","error":"Set a password before disconnecting your final sign-in account."}"#)

            let missing = try await send(client, .delete, "/api/auth/identities/apple", bearer: fixture.bearer)
            #expect(missing.body.string == #"{"unlinked":false,"identities":[{"provider":"github","providerEmail":"gh@example.com"}],"passwordConfigured":false}"#)
        }
    }
}

@Test func authLoginRouteReadsRawJSONAndPublishesTheIssueList() async throws {
    let fixture = byteFixture()
    fixture.accounts.markPasswordCredentialEstablished(userId: fixture.userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let missing = try await send(client, .post, "/api/auth/login", body: #"{"password":1}"#)
            #expect(missing.status == .badRequest)
            #expect(missing.body.string == #"{"error":"Invalid email login body","code":"email_login_body_invalid","issues":[{"path":"email","message":"Required"},{"path":"password","message":"Expected string, received boolean"}]}"#)

            let notObject = try await send(client, .post, "/api/auth/login", body: "[]")
            #expect(notObject.body.string == #"{"error":"Invalid email login body","code":"email_login_body_invalid","issues":[{"path":"","message":"Expected object, received string"}]}"#)
            let empty = try await send(client, .post, "/api/auth/login")
            #expect(empty.status == .badRequest)

            let rejected = try await send(client, .post, "/api/auth/login", body: #"{"email":"bytes@slock.test","password":"nope"}"#)
            #expect(rejected.status == .unauthorized)
            #expect(rejected.body.string == #"{"code":"AUTH_INVALID_CREDENTIALS","error":"Invalid email or password"}"#)

            // A client that omitted the JSON content type is still read as JSON.
            let plain = try await send(client, .post, "/api/auth/login", contentType: nil, body: #"{"email":"bytes@slock.test","password":"password123"}"#)
            #expect(plain.status == .ok)
            let text = plain.body.string ?? ""
            #expect(text.hasPrefix(#"{"user":{"id":"\#(fixture.userId)","email":"bytes@slock.test","gravatarHash":""#))
            #expect(text.hasSuffix(#","linkedProvider":null}"#))
            expectStandard(plain, length: text.utf8.count)

            let formTyped = try await send(client, .post, "/api/auth/login", contentType: "text/plain", body: #"{"email":"bytes@slock.test","password":"password123"}"#)
            #expect(formTyped.status == .ok)
        }
    }
}

@Test func appLoginAndProfileRoutesPublishTheLegacyBytes() async throws {
    let fixture = byteFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let invalid = try await send(client, .post, "/api/auth/app-login/start", body: "[]")
            #expect(invalid.status == .badRequest)
            #expect(invalid.body.string == #"{"error":"Invalid app login request","code":"invalid_request"}"#)
            let notAllowed = try await send(client, .post, "/api/auth/app-login/start", body: #"{"returnUri":"https://x.test","codeChallenge":"a"}"#)
            #expect(notAllowed.body.string == #"{"error":"Return URI is not allowed","code":"return_uri_not_allowed"}"#)
            let challenge = String(repeating: "A", count: 43)
            let started = try await send(client, .post, "/api/auth/app-login/start", contentType: nil, body: #"{"returnUri":"raft://login/callback","codeChallenge":"\#(challenge)"}"#)
            #expect(started.status == .created)
            let startedText = started.body.string ?? ""
            #expect(startedText.hasPrefix(#"{"requestId":""#))
            #expect(startedText.contains(#","loginUrl":"https://app.raft.test/login/app?request="#))
            #expect(startedText.contains(#"","expiresAt":""#))
            let completeInvalid = try await send(client, .post, "/api/auth/app-login/complete", body: "")
            #expect(completeInvalid.body.string == #"{"error":"Invalid app login completion","code":"invalid_request"}"#)
            let notFound = try await send(client, .get, "/api/auth/app-login/requests/missing", bearer: fixture.bearer)
            #expect(notFound.status == .notFound)
            #expect(notFound.body.string == #"{"error":"App login request not found","code":"request_not_found"}"#)
            let noToken = try await send(client, .post, "/api/auth/app-login/requests/missing/deny")
            #expect(noToken.body.string == #"{"error":"Invalid or expired token","code":"auth_required"}"#)

            let meMissing = try await send(client, .get, "/api/auth/me")
            #expect(meMissing.body.string == #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#)
            let me = try await send(client, .get, "/api/auth/me", bearer: fixture.bearer)
            #expect(me.status == .ok)
            let meText = me.body.string ?? ""
            #expect(meText.hasPrefix(#"{"id":"\#(fixture.userId)","email":"bytes@slock.test","gravatarHash":""#))
            #expect(meText.contains(#","name":"bytes","displayName":null,"description":null,"avatarUrl":null,"emailVerified":false,"preferredLanguage":null,"displayLanguage":null,"preferredTimezone":null,"firstObservedTimezone":null,"firstObservedTimezoneAt":null,"lastObservedTimezone":null,"lastObservedTimezoneAt":null,"#))
            #expect(meText.hasSuffix(#","signupSurveyCompletedAt":null,"signupRole":null,"profileSetupProvider":null}"#))

            let notObject = try await send(client, .patch, "/api/auth/me", bearer: fixture.bearer, body: "[1]")
            #expect(notObject.status == .badRequest)
            #expect(notObject.body.string == #"{"error":"Failed to update profile"}"#)
            let unauthenticated = try await send(client, .patch, "/api/auth/me", body: "[1]")
            #expect(unauthenticated.status == .unauthorized)
            let badZone = try await send(client, .patch, "/api/auth/me", bearer: fixture.bearer, body: #"{"preferredTimezone":"Nope/Zone"}"#)
            #expect(badZone.body.string == #"{"error":"Invalid preferredTimezone"}"#)
            let wrongPassword = try await send(client, .patch, "/api/auth/me", bearer: fixture.bearer, body: #"{"currentPassword":"bad","newPassword":"longenough1"}"#)
            #expect(wrongPassword.body.string == #"{"code":"AUTH_CURRENT_PASSWORD_INCORRECT","error":"Current password is incorrect"}"#)
            let patched = try await send(client, .patch, "/api/auth/me", bearer: fixture.bearer, contentType: "text/plain", body: #"{"preferredTranslationMode":"auto","shareUsageData":0}"#)
            #expect(patched.status == .ok)
            #expect((patched.body.string ?? "").contains(#""shareUsageData":false,"#))
            #expect((patched.body.string ?? "").contains(#""preferredTranslationMode":"auto""#))

            let noAvatar = try await send(client, .post, "/api/auth/me/avatar", bearer: fixture.bearer, contentType: "text/plain", body: "x")
            #expect(noAvatar.body.string == #"{"error":"No avatar file provided"}"#)
        }
    }
}


@Test func passwordLoginPublishesStoredVerificationAndProfileForEveryBrowserGateState() async throws {
    let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
    for verified in [false, true] {
        for completed in [false, true] {
            // Each combination owns a fresh synthetic account. No production
            // seed, deployment state or session file is read or changed.
            let accounts = EmailLoginDirectory()
            let userId = UUID().uuidString.lowercased()
            let email = "projection-\(userId)@auth.test"
            accounts.addAccount(id: userId, email: email, password: "projection-test-password")
            accounts.linkIdentityForTesting(
                userId: userId, provider: "github", providerUserId: "projection-github",
                providerEmail: email
            )
            accounts.authProfileStore.state.withLock { owned in
                owned.accountSurface.accounts[email]?.emailVerified = verified
                owned.accountSurface.accounts[email]?.name = completed ? "ready-handle" : ""
                owned.accountSurface.accounts[email]?.displayName = "Projection é😀"
                owned.accountSurface.accounts[email]?.profileSetupCompletedAt = completed ? completedAt : nil
                owned.accountSurface.accounts[email]?.profileSetupSuggestedHandle = "suggested-handle"
                owned.accountSurface.accounts[email]?.profileSetupProvider = "github"
                owned.accountSurface.accounts[email]?.preferredMessageBodyFontSize = "lg"
            }
            try await withApp { app in
                configure(app, services: FallbackServices(
                    nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
                ))
                try await app.testing { client in
                    let body = try JSONSerialization.data(withJSONObject: [
                        "email": email, "password": "projection-test-password",
                        "emailVerified": !verified, "name": "forged-handle",
                        "profileSetupCompletedAt": "2099-01-01T00:00:00.000Z",
                    ] as [String: Any])
                    let response = try await send(client, .post, "/api/auth/login", body: String(decoding: body, as: UTF8.self))
                    try #require(response.status == .ok)
                    let json = try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
                    let user = try #require(json["user"] as? [String: Any])
                    #expect(user["id"] as? String == userId)
                    #expect(user["email"] as? String == email)
                    #expect(user["emailVerified"] as? Bool == verified)
                    #expect(user["name"] as? String == (completed ? "ready-handle" : ""))
                    #expect(user["displayName"] as? String == "Projection é😀")
                    if completed {
                        #expect(user["profileSetupCompletedAt"] as? String == "2023-11-14T22:13:20.000Z")
                    } else {
                        #expect(user["profileSetupCompletedAt"] is NSNull)
                    }
                    #expect(user["profileSetupSuggestedHandle"] as? String == "suggested-handle")
                    #expect(user["profileSetupProvider"] as? String == "github")
                    #expect(user["preferredMessageBodyFontSize"] as? String == "lg")
                    #expect(user["gravatarHash"] as? String == AuthTokenCodec.sha256(email))
                    for privateField in ["passwordHash", "passwordCredentialEstablishedAt", "accessToken", "refreshToken", "verificationToken"] {
                        #expect(user[privateField] == nil, Comment(rawValue: privateField))
                    }
                    let accessToken = try #require(json["accessToken"] as? String)
                    let refreshToken = try #require(json["refreshToken"] as? String)
                    #expect(!accessToken.isEmpty && !refreshToken.isEmpty)
                    expectStandard(response, length: (response.body.string ?? "").utf8.count)
                    let me = try await send(client, .get, "/api/auth/me", bearer: accessToken)
                    try #require(me.status == .ok)
                    let meUser = try #require(try JSONSerialization.jsonObject(with: Data((me.body.string ?? "").utf8)) as? [String: Any])
                    let loginPublicJSON = try JSONSerialization.data(withJSONObject: user, options: [.sortedKeys])
                    let currentPublicJSON = try JSONSerialization.data(withJSONObject: meUser, options: [.sortedKeys])
                    #expect(loginPublicJSON == currentPublicJSON)
                    let rejected = try await send(client, .post, "/api/auth/login", body: "{\"email\":\"\(email)\",\"password\":\"wrong\"}")
                    #expect(rejected.status == .unauthorized)
                    #expect(rejected.body.string == #"{"code":"AUTH_INVALID_CREDENTIALS","error":"Invalid email or password"}"#)
                }
            }
        }
    }
}
