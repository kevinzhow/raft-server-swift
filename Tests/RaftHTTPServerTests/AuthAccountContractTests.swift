import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func authJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func authRegister(
    _ client: any Client,
    body: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/register") { request in
        request.body = .init(string: body)
    }
    return (response.status, try authJSON(response))
}

private func authLogin(
    _ client: any Client,
    email: String,
    password: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: #"{"email":"\#(email)","password":"\#(password)"}"#)
    }
    return (response.status, try authJSON(response))
}

private func authMe(
    _ client: any Client,
    token: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    let response = try await client.send(.get, headers: headers, to: "/api/auth/me")
    return (response.status, try authJSON(response))
}

private func authPatchMe(
    _ client: any Client,
    token: String,
    body: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    let response = try await client.send(.patch, headers: headers, to: "/api/auth/me") { request in
        request.body = .init(string: body)
    }
    return (response.status, try authJSON(response))
}

@Test func authRegistrationRefusesReservedHandlesAndUnacceptedLegalTerms() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let reserved = try await authRegister(
                client,
                body: #"{"email":"register-reminders@slock.test","password":"password123","name":"Reminders","acceptTerms":true,"termsVersion":"\#(EmailLoginDirectory.termsVersion)","privacyVersion":"\#(EmailLoginDirectory.privacyVersion)"}"#
            )
            #expect(reserved.status == .badRequest)
            #expect((reserved.body["error"] as? String)?.lowercased().contains("reserved") == true)
            #expect(!accounts.hasAccount(email: "register-reminders@slock.test"))

            let missingLegal = try await authRegister(
                client,
                body: #"{"email":"legal-missing@slock.test","password":"password123","name":"legal-missing"}"#
            )
            #expect(missingLegal.status == .unprocessableContent)
            #expect(missingLegal.body["error"] as? String == "LEGAL_ACCEPTANCE_REQUIRED")
            let legal = try #require(missingLegal.body["legal"] as? [String: Any])
            #expect(legal["termsVersion"] as? String == EmailLoginDirectory.termsVersion)
            #expect(legal["privacyVersion"] as? String == EmailLoginDirectory.privacyVersion)
            #expect(!accounts.hasAccount(email: "legal-missing@slock.test"))

            let staleLegal = try await authRegister(
                client,
                body: #"{"email":"legal-stale@slock.test","password":"password123","name":"legal-stale","acceptTerms":true,"termsVersion":"old-terms","privacyVersion":"\#(EmailLoginDirectory.privacyVersion)"}"#
            )
            #expect(staleLegal.status == .conflict)
            #expect(staleLegal.body["error"] as? String == "TERMS_CHANGED")
            #expect(!accounts.hasAccount(email: "legal-stale@slock.test"))

            let accepted = try await authRegister(
                client,
                body: #"{"email":"legal-accepted@slock.test","password":"password123","name":"legal-accepted","acceptTerms":true,"termsVersion":"\#(EmailLoginDirectory.termsVersion)","privacyVersion":"\#(EmailLoginDirectory.privacyVersion)"}"#
            )
            #expect(accepted.status == .ok)
            #expect(accounts.hasAccount(email: "legal-accepted@slock.test"))
            let acceptedUserId = try #require(accounts.userId(forEmail: "legal-accepted@slock.test"))
            let acceptance = try #require(accounts.legalAcceptance(userId: acceptedUserId))
            #expect(acceptance.termsVersion == EmailLoginDirectory.termsVersion)
            #expect(acceptance.privacyVersion == EmailLoginDirectory.privacyVersion)
            #expect(acceptance.source == "signup")
        }
    }
}

@Test func authLoginUsesStableCredentialAndBodyCodes() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: "11111111-1111-4111-8111-000001320901", email: "wrong-password@slock.test", password: "password123")
    accounts.markEmailVerified(userId: "11111111-1111-4111-8111-000001320901")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let wrong = try await authLogin(client, email: "wrong-password@slock.test", password: "not-the-password")
            #expect(wrong.status == .unauthorized)
            #expect(wrong.body["code"] as? String == "AUTH_INVALID_CREDENTIALS")
            #expect(wrong.body["error"] as? String == "Invalid email or password")

            for (body, path) in [
                (#"{"email":{"address":"object-email@slock.test"},"password":"password123"}"#, "email"),
                (#"{"email":"object-password@slock.test","password":{"raw":"password123"}}"#, "password"),
            ] {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: body)
                }
                #expect(response.status == .badRequest)
                let parsed = try authJSON(response)
                #expect(parsed["code"] as? String == "email_login_body_invalid")
                let issues = (parsed["issues"] as? [[String: Any]]) ?? []
                #expect(issues.contains { $0["path"] as? String == path })
            }
        }
    }
}

@Test func authProfilePatchKeepsStablePasswordAndDisplayLanguageRules() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001320902"
    accounts.addAccount(id: userId, email: "profile-contract@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let login = try await authLogin(client, email: "profile-contract@slock.test", password: "password123")
            let token = try #require(login.body["accessToken"] as? String)

            let wrongPassword = try await authPatchMe(
                client,
                token: token,
                body: #"{"currentPassword":"wrong-password","newPassword":"new-password-123"}"#
            )
            #expect(wrongPassword.status == .unauthorized)
            #expect(wrongPassword.body["code"] as? String == "AUTH_CURRENT_PASSWORD_INCORRECT")
            #expect(wrongPassword.body["error"] as? String == "Current password is incorrect")

            let setChinese = try await authPatchMe(client, token: token, body: #"{"displayLanguage":"zh-Hans"}"#)
            #expect(setChinese.status == .ok)
            #expect(setChinese.body["displayLanguage"] as? String == "zh-cn")
            #expect(try await authMe(client, token: token).body["displayLanguage"] as? String == "zh-cn")

            _ = try await authPatchMe(client, token: token, body: #"{"displayLanguage":"en-US"}"#)
            #expect(try await authMe(client, token: token).body["displayLanguage"] as? String == "en")

            let unsupported = try await authPatchMe(client, token: token, body: #"{"displayLanguage":"fr-FR"}"#)
            #expect(unsupported.status == .badRequest)
            #expect(try await authMe(client, token: token).body["displayLanguage"] as? String == "en")

            let traditional = try await authPatchMe(client, token: token, body: #"{"displayLanguage":"zh-TW"}"#)
            #expect(traditional.status == .badRequest)
            #expect(try await authMe(client, token: token).body["displayLanguage"] as? String == "en")

            let cleared = try await authPatchMe(client, token: token, body: #"{"displayLanguage":null}"#)
            #expect(cleared.status == .ok)
            let clearedBody = try await authMe(client, token: token)
            #expect(clearedBody.body["displayLanguage"] == nil || clearedBody.body["displayLanguage"] is NSNull)
        }
    }
}

@Test func authProfileShareUsageDataAndGravatarHash() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000001320903"
    let email = "share-usage-data@slock.test"
    accounts.addAccount(id: userId, email: email, password: "password123")
    accounts.markEmailVerified(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let login = try await authLogin(client, email: email, password: "password123")
            let token = try #require(login.body["accessToken"] as? String)

            let initial = try await authMe(client, token: token)
            #expect(initial.status == .ok)
            #expect(initial.body["shareUsageData"] == nil || initial.body["shareUsageData"] is NSNull, "not chosen until the user says so")
            let gravatar = try #require(initial.body["gravatarHash"] as? String)
            let expected = SHA256.hash(data: Data(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            #expect(gravatar == expected)

            for value in ["true", "false", "null"] {
                let patched = try await authPatchMe(client, token: token, body: #"{"shareUsageData":\#(value)}"#)
                #expect(patched.status == .ok)
                switch value {
                case "true":
                    #expect(patched.body["shareUsageData"] as? Bool == true)
                case "false":
                    #expect(patched.body["shareUsageData"] as? Bool == false)
                default:
                    #expect(patched.body["shareUsageData"] == nil || patched.body["shareUsageData"] is NSNull)
                }
            }
            let invalid = try await authPatchMe(client, token: token, body: #"{"shareUsageData":"yes"}"#)
            #expect(invalid.status == .badRequest)
        }
    }
}
