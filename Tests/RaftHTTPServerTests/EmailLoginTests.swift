import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func avatarMultipart(filename: String, mime: String, bytes: Data) -> (contentType: String, body: Data) {
    let boundary = "avatar-boundary"
    var body = Data()
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
    body.append(bytes)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return ("multipart/form-data; boundary=\(boundary)", body)
}

private func postBytes(_ client: any Client, _ path: String, contentType: String, body: Data, authorization: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = contentType
    headers[.authorization] = authorization
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(data: body)
    }
}

private func postJSON(_ client: any Client, _ path: String, body: String, authorization: String? = nil) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let authorization {
        headers[.authorization] = authorization
    }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

@Test func emailLoginRejectsAMalformedBodyBeforeAnySession() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: "11111111-1111-4111-8111-111111111111", email: "malformed-email@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let objectEmail = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":{\"address\":\"malformed-email@slock.test\"},\"password\":\"password123\"}"
            )
            #expect(objectEmail.status == .badRequest)
            let emailBody = try JSONSerialization.jsonObject(with: Data(bodyText(objectEmail).utf8)) as? [String: Any]
            #expect(emailBody?["code"] as? String == "email_login_body_invalid")
            #expect(emailBody?["error"] as? String == "Invalid email login body")
            let emailIssues = emailBody?["issues"] as? [[String: Any]] ?? []
            #expect(emailIssues.contains { $0["path"] as? String == "email" })

            let objectPassword = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"malformed-password@slock.test\",\"password\":{\"raw\":\"password123\"}}"
            )
            #expect(objectPassword.status == .badRequest)
            let passwordBody = try JSONSerialization.jsonObject(with: Data(bodyText(objectPassword).utf8)) as? [String: Any]
            #expect(passwordBody?["code"] as? String == "email_login_body_invalid")
            let passwordIssues = passwordBody?["issues"] as? [[String: Any]] ?? []
            #expect(passwordIssues.contains { $0["path"] as? String == "password" })
            #expect(accounts.sessionCount == 0)
        }
    }
}

@Test func emailLoginUsesOneBodyForAnUnknownUserAndAWrongPassword() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "22222222-2222-4222-8222-222222222222"
    accounts.addAccount(id: userId, email: "wrong-password@slock.test", password: "password123")
    let denied = "{\"code\":\"AUTH_INVALID_CREDENTIALS\",\"error\":\"Invalid email or password\"}"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let unknown = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"missing-login-user@slock.test\",\"password\":\"not-the-password\"}"
            )
            #expect(unknown.status == .unauthorized)
            #expect(bodyText(unknown) == denied)
            #expect(unknown.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")

            let mismatch = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"Wrong-Password@Slock.test\",\"password\":\"not-the-password\"}"
            )
            #expect(mismatch.status == .unauthorized)
            #expect(bodyText(mismatch) == denied)
            #expect(bodyText(mismatch).contains("not-the-password") == false)
            #expect(accounts.sessionCount == 0)

            let accepted = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"wrong-password@slock.test\",\"password\":\"password123\"}"
            )
            #expect(accepted.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(accepted).utf8)) as? [String: Any]
            let accessToken = body?["accessToken"] as? String
            let refreshToken = body?["refreshToken"] as? String
            #expect(accessToken?.isEmpty == false)
            #expect(refreshToken?.isEmpty == false)
            #expect(accessToken != refreshToken)
            #expect(bodyText(accepted).contains("password123") == false)
            let user = body?["user"] as? [String: Any]
            #expect(user?["id"] as? String == userId)
            #expect(user?["email"] as? String == "wrong-password@slock.test")
            #expect(accounts.sessionCount == 1)
        }
    }
}

@Test func currentUserGravatarHashFollowsTheAccessToken() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "33333333-3333-4333-8333-333333333333"
    accounts.addAccount(id: userId, email: "  Gravatar-Self@Slock.test  ", password: "password123")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let missing = try await client.get("/api/auth/me")
            #expect(missing.status == .unauthorized)
            #expect(bodyText(missing) == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")

            let expired = try await client.get("/api/auth/me", headers: [
                HTTPField.Name("Authorization")!: "Bearer not-a-session",
            ])
            #expect(expired.status == .unauthorized)
            #expect(bodyText(expired) == "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")

            let login = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"gravatar-self@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let loginBody = try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any]
            let token = loginBody?["accessToken"] as? String ?? ""
            #expect(token.isEmpty == false)

            let me = try await client.get("/api/auth/me", headers: [
                HTTPField.Name("Authorization")!: "Bearer \(token)",
            ])
            #expect(me.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(me).utf8)) as? [String: Any]
            #expect(body?["id"] as? String == userId)
            #expect(body?["email"] as? String == "gravatar-self@slock.test")
            #expect(body?["gravatarHash"] as? String == "be6daabc60a1c0c8bb1538ece5f572df6f29f14f53891bd8e4b9b0690d05ec57")
            #expect(bodyText(me).contains("password123") == false)
        }
    }
}

private func patchJSON(_ client: any Client, token: String, body: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("Authorization")!] = "Bearer \(token)"
    return try await client.send(.patch, headers: headers, to: URI(string: "/api/auth/me")) { request in
        request.body = .init(string: body)
    }
}

private func displayLanguage(_ body: [String: Any]) -> String? {
    if body["displayLanguage"] is NSNull { return nil }
    return body["displayLanguage"] as? String
}

@Test func patchCurrentPasswordRejectsAWrongPasswordAndKeepsTheOldOne() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: "44444444-4444-4444-8444-444444444444", email: "current-password@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"current-password@slock.test\",\"password\":\"password123\"}"
            )
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            #expect(token.isEmpty == false)

            let wrong = try await patchJSON(
                client,
                token: token,
                body: "{\"currentPassword\":\"wrong-password\",\"newPassword\":\"new-password-123\"}"
            )
            #expect(wrong.status == .unauthorized)
            #expect(bodyText(wrong) == "{\"code\":\"AUTH_CURRENT_PASSWORD_INCORRECT\",\"error\":\"Current password is incorrect\"}")

            let stillOld = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"current-password@slock.test\",\"password\":\"password123\"}"
            )
            #expect(stillOld.status == .ok)
            let changed = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"current-password@slock.test\",\"password\":\"new-password-123\"}"
            )
            #expect(changed.status == .unauthorized)

            let updated = try await patchJSON(
                client,
                token: token,
                body: "{\"currentPassword\":\"password123\",\"newPassword\":\"new-password-123\"}"
            )
            #expect(updated.status == .ok)
            #expect(bodyText(updated).contains("new-password-123") == false)
            let oldDenied = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"current-password@slock.test\",\"password\":\"password123\"}"
            )
            #expect(oldDenied.status == .unauthorized)
            let withNew = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"current-password@slock.test\",\"password\":\"new-password-123\"}"
            )
            #expect(withNew.status == .ok)
        }
    }
}

@Test func patchDisplayLanguageNormalizesPersistsAndRejectsUnrenderable() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: "55555555-5555-4555-8555-555555555555", email: "display-language@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"display-language@slock.test\",\"password\":\"password123\"}"
            )
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""

            func patch(_ body: String) async throws -> ClientResponse {
                try await patchJSON(client, token: token, body: body)
            }
            func stored() async throws -> String? {
                let response = try await client.get("/api/auth/me", headers: [
                    HTTPField.Name("Authorization")!: "Bearer \(token)",
                ])
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any] ?? [:]
                #expect(body.keys.contains("displayLanguage"))
                return displayLanguage(body)
            }

            let set = try await patch("{\"displayLanguage\":\"zh-Hans\"}")
            #expect(set.status == .ok)
            let setBody = try JSONSerialization.jsonObject(with: Data(bodyText(set).utf8)) as? [String: Any] ?? [:]
            #expect(displayLanguage(setBody) == "zh-cn")
            #expect(try await stored() == "zh-cn")

            _ = try await patch("{\"displayLanguage\":\"en-US\"}")
            #expect(try await stored() == "en")

            let french = try await patch("{\"displayLanguage\":\"fr-FR\"}")
            #expect(french.status == .badRequest)
            #expect(bodyText(french) == "{\"error\":\"displayLanguage must be a supported UI display locale\"}")
            #expect(try await stored() == "en")

            let traditional = try await patch("{\"displayLanguage\":\"zh-TW\"}")
            #expect(traditional.status == .badRequest)
            #expect(try await stored() == "en")

            let cleared = try await patch("{\"displayLanguage\":null}")
            #expect(cleared.status == .ok)
            let clearedBody = try JSONSerialization.jsonObject(with: Data(bodyText(cleared).utf8)) as? [String: Any] ?? [:]
            #expect(clearedBody.keys.contains("displayLanguage"))
            #expect(displayLanguage(clearedBody) == nil)
            #expect(try await stored() == nil)
        }
    }
}

private func registerJSON(
    _ client: any Client,
    body: String,
    userAgent: String? = nil,
    acceptLanguage: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let userAgent { headers[.userAgent] = userAgent }
    if let acceptLanguage { headers[.acceptLanguage] = acceptLanguage }
    return try await client.send(.post, headers: headers, to: URI(string: "/api/auth/register")) { request in
        request.body = .init(string: body)
    }
}

@Test func registerRejectsAnObjectFieldBeforeAnyAccount() async throws {
    let accounts = EmailLoginDirectory()
    let terms = AuthLegalPolicy.termsVersion
    let privacy = AuthLegalPolicy.privacyVersion
    let bodies = [
        "{\"email\":{\"address\":\"register-object-email@slock.test\"},\"password\":\"password123\",\"name\":\"register-object-email\",\"acceptTerms\":true,\"termsVersion\":\"\(terms)\",\"privacyVersion\":\"\(privacy)\"}",
        "{\"email\":\"register-object-password@slock.test\",\"password\":{\"raw\":\"password123\"},\"name\":\"register-object-password\",\"acceptTerms\":true,\"termsVersion\":\"\(terms)\",\"privacyVersion\":\"\(privacy)\"}",
        "{\"email\":\"register-object-name@slock.test\",\"password\":\"password123\",\"name\":{\"display\":\"register-object-name\"},\"acceptTerms\":true,\"termsVersion\":\"\(terms)\",\"privacyVersion\":\"\(privacy)\"}",
    ]
    let paths = ["email", "password", "name"]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            for (body, path) in zip(bodies, paths) {
                let response = try await registerJSON(client, body: body)
                #expect(response.status == .badRequest)
                let parsed = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
                #expect(parsed?["code"] as? String == "email_register_body_invalid")
                #expect(parsed?["error"] as? String == "Invalid email registration body")
                let issues = parsed?["issues"] as? [[String: Any]] ?? []
                #expect(issues.contains { $0["path"] as? String == path })
                #expect(accounts.userCount == 0)
                #expect(accounts.legalAcceptanceCount == 0)
                #expect(accounts.emailVerificationCount == 0)
                #expect(accounts.sessionCount == 0)
            }
        }
    }
}

@Test func stagingSelfAccountRetirementIsOwnerBoundAndIdempotent() async throws {
    let accounts = EmailLoginDirectory()
    accounts.releaseBranch = "staging"
    let otherId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"
    accounts.addAccount(id: otherId, email: "retire-other@mail.build", password: "password123")
    accounts.markEmailVerified(userId: otherId)
    let capability = "retirement-capability-owner-1234567890"
    let terms = AuthLegalPolicy.termsVersion
    let privacy = AuthLegalPolicy.privacyVersion
    let registerBody = "{\"email\":\"retire-owner@mail.build\",\"password\":\"password123\",\"name\":\"retire-owner\",\"acceptTerms\":true,\"termsVersion\":\"\(terms)\",\"privacyVersion\":\"\(privacy)\",\"stagingSelfAccountCapability\":\"\(capability)\"}"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let registration = try await registerJSON(client, body: registerBody)
            #expect(registration.status == .ok)
            let registered = try JSONSerialization.jsonObject(with: Data(bodyText(registration).utf8)) as? [String: Any]
            let owner = registered?["user"] as? [String: Any]
            let ownerId = owner?["id"] as? String ?? ""
            let ownerEmail = owner?["email"] as? String ?? ""
            #expect(ownerEmail == "retire-owner@mail.build")
            #expect(accounts.stagingSelfAccountCapabilityHash(userId: ownerId) == AuthTokenCodec.sha256Hex(capability))
            accounts.markEmailVerified(userId: ownerId)

            let ownerLogin = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}"
            )
            #expect(ownerLogin.status == .ok)
            let ownerSession = try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any]
            let ownerToken = ownerSession?["accessToken"] as? String ?? ""
            let refreshToken = ownerSession?["refreshToken"] as? String ?? ""
            let otherLogin = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"retire-other@mail.build\",\"password\":\"password123\"}"
            )
            let otherToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(otherLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""

            let crossUser = try await postJSON(
                client,
                "/api/auth/staging-self-account/retire",
                body: "{\"userId\":\"\(otherId)\",\"capability\":\"\(capability)\"}",
                authorization: "Bearer \(ownerToken)"
            )
            #expect(crossUser.status == .forbidden)
            let crossBody = try JSONSerialization.jsonObject(with: Data(bodyText(crossUser).utf8)) as? [String: Any]
            #expect(crossBody?["error"] as? String == "User ownership mismatch")
            #expect(accounts.retirementReceiptCount == 0)

            let wrongCapability = try await postJSON(
                client,
                "/api/auth/staging-self-account/retire",
                body: "{\"userId\":\"\(ownerId)\",\"capability\":\"wrong-capability-12345678901234567890\"}",
                authorization: "Bearer \(ownerToken)"
            )
            #expect(wrongCapability.status == .forbidden)
            let wrongBody = try JSONSerialization.jsonObject(with: Data(bodyText(wrongCapability).utf8)) as? [String: Any]
            #expect(wrongBody?["error"] as? String == "Invalid retirement capability")
            #expect(accounts.retirementReceiptCount == 0)

            let sharedAccount = try await postJSON(
                client,
                "/api/auth/staging-self-account/retire",
                body: "{\"userId\":\"\(otherId)\",\"capability\":\"\(capability)\"}",
                authorization: "Bearer \(otherToken)"
            )
            #expect(sharedAccount.status == .forbidden)
            let sharedBody = try JSONSerialization.jsonObject(with: Data(bodyText(sharedAccount).utf8)) as? [String: Any]
            #expect(sharedBody?["error"] as? String == "Invalid retirement capability")
            #expect(accounts.retirementReceiptCount == 0)

            let first = try await postJSON(
                client,
                "/api/auth/staging-self-account/retire",
                body: "{\"userId\":\"\(ownerId)\",\"capability\":\"\(capability)\"}",
                authorization: "Bearer \(ownerToken)"
            )
            #expect(first.status == .ok)
            let firstText = bodyText(first)
            let firstBody = try JSONSerialization.jsonObject(with: Data(firstText.utf8)) as? [String: Any]
            let receipt = firstBody?["receipt"] as? [String: Any]
            #expect(receipt?["userId"] as? String == ownerId)
            #expect(receipt?["actorUserId"] as? String == ownerId)
            #expect(receipt?["environment"] as? String == "staging")
            #expect(receipt?["terminalState"] as? String == "retired")
            #expect((receipt?["sessionsRevoked"] as? NSNumber)?.intValue == 2)
            #expect(firstText.contains(ownerEmail) == false)
            #expect(firstText.contains(refreshToken) == false)

            let second = try await postJSON(
                client,
                "/api/auth/staging-self-account/retire",
                body: "{\"userId\":\"\(ownerId)\",\"capability\":\"\(capability)\"}",
                authorization: "Bearer \(ownerToken)"
            )
            #expect(second.status == .ok)
            #expect(bodyText(second) == firstText)
            #expect(accounts.retiredAt(userId: ownerId) != nil)
            #expect(accounts.sessionCount(for: ownerId) == 0)
            let revoked = accounts.sessionFamilyRevokedAts(userId: ownerId)
            #expect(revoked.isEmpty == false)
            #expect(revoked.allSatisfy { $0 != nil })
            #expect(accounts.retirementReceiptCount == 1)

            let passwordDenied = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}"
            )
            #expect(passwordDenied.status == .unauthorized)
            let refreshDenied = try await postJSON(
                client,
                "/api/auth/refresh",
                body: "{\"refreshToken\":\"\(refreshToken)\"}"
            )
            #expect(refreshDenied.status == .unauthorized)
            let oldAccess = try await client.get("/api/auth/me", headers: [
                HTTPField.Name("Authorization")!: "Bearer \(ownerToken)",
            ])
            #expect(oldAccess.status == .unauthorized)
            #expect(accounts.sessionCount(for: ownerId) == 0)
        }
    }
}

@Test func stagingSelfAccountRegistrationFailsClosedOutsideStaging() async throws {
    let accounts = EmailLoginDirectory()
    let terms = AuthLegalPolicy.termsVersion
    let privacy = AuthLegalPolicy.privacyVersion
    let email = "production-opt-in@mail.build"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let response = try await registerJSON(
                client,
                body: "{\"email\":\"\(email)\",\"password\":\"password123\",\"name\":\"production-opt-in\",\"acceptTerms\":true,\"termsVersion\":\"\(terms)\",\"privacyVersion\":\"\(privacy)\",\"stagingSelfAccountCapability\":\"production-opt-in-capability-1234567890\"}"
            )
            #expect(response.status == .forbidden)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
            #expect(body?["error"] as? String == "Staging self-account registration is unavailable")
            #expect(accounts.hasAccount(email: email) == false)
            #expect(accounts.userCount == 0)
            #expect(accounts.legalAcceptanceCount == 0)
            #expect(accounts.sessionCount == 0)
        }
    }
}

@Test func registerRequiresCurrentLegalAcceptance() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let missing = try await registerJSON(
                client,
                body: "{\"email\":\"legal-missing@slock.test\",\"password\":\"password123\",\"name\":\"legal-missing\"}"
            )
            #expect(missing.status == .unprocessableContent)
            let missingBody = try JSONSerialization.jsonObject(with: Data(bodyText(missing).utf8)) as? [String: Any]
            #expect(missingBody?["error"] as? String == "LEGAL_ACCEPTANCE_REQUIRED")
            let legal = missingBody?["legal"] as? [String: Any]
            #expect(legal?["termsVersion"] as? String == "2026-05-12")
            #expect(legal?["privacyVersion"] as? String == "2026-05-12")
            #expect(accounts.hasAccount(email: "legal-missing@slock.test") == false)
            #expect(accounts.sessionCount == 0)

            let stale = try await registerJSON(
                client,
                body: "{\"email\":\"legal-stale@slock.test\",\"password\":\"password123\",\"name\":\"legal-stale\",\"acceptTerms\":true,\"termsVersion\":\"old-terms\",\"privacyVersion\":\"2026-05-12\"}"
            )
            #expect(stale.status == .conflict)
            let staleBody = try JSONSerialization.jsonObject(with: Data(bodyText(stale).utf8)) as? [String: Any]
            #expect(staleBody?["error"] as? String == "TERMS_CHANGED")
            #expect(accounts.hasAccount(email: "legal-stale@slock.test") == false)

            let accepted = try await registerJSON(
                client,
                body: "{\"email\":\"legal-ok@slock.test\",\"password\":\"password123\",\"name\":\"legal-ok\",\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\"}",
                userAgent: "legal-test-agent",
                acceptLanguage: "en-US"
            )
            #expect(accepted.status == .ok)
            let acceptedBody = try JSONSerialization.jsonObject(with: Data(bodyText(accepted).utf8)) as? [String: Any]
            let userId = (acceptedBody?["user"] as? [String: Any])?["id"] as? String ?? ""
            #expect(userId.isEmpty == false)
            let record = accounts.legalAcceptance(userId: userId)
            #expect(record == EmailLegalAcceptance(
                termsVersion: "2026-05-12",
                privacyVersion: "2026-05-12",
                termsUrl: "https://raft.build/terms",
                privacyUrl: "https://raft.build/privacy",
                source: "signup",
                userAgentHash: "6b795b17699a9eb5ffcbd42ebe2082c29eec18deae5a7169122609fd995f37e6",
                locale: "en-US"
            ))
            #expect(record?.userAgentHash != "legal-test-agent")
            #expect(accounts.hasAccount(email: "legal-ok@slock.test"))
            #expect(accounts.sessionCount == 1)

            let invited = try await registerJSON(
                client,
                body: "{\"email\":\"legal-invite@slock.test\",\"password\":\"password123\",\"name\":\"legal-invite\",\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\",\"legalAcceptanceSource\":\"invite\"}"
            )
            #expect(invited.status == .ok)
            let invitedId = ((try JSONSerialization.jsonObject(with: Data(bodyText(invited).utf8)) as? [String: Any])?["user"] as? [String: Any])?["id"] as? String ?? ""
            #expect(accounts.legalAcceptance(userId: invitedId)?.source == "invite")
        }
    }
}

@Test func registerRefusesAReservedHandleSuchAsReminders() async throws {
    let accounts = EmailLoginDirectory()
    let legal = "\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\""
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let before = accounts.sessionCount
            let reserved = try await registerJSON(
                client,
                body: "{\"email\":\"register-reminders@slock.test\",\"password\":\"password123\",\"name\":\"Reminders\",\(legal)}"
            )
            #expect(reserved.status == .badRequest)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(reserved).utf8)) as? [String: Any]
            #expect(body?["error"] as? String == "This username is reserved. Choose another name.")
            #expect(accounts.hasAccount(email: "register-reminders@slock.test") == false)
            #expect(accounts.sessionCount == before)

            let allowed = try await registerJSON(
                client,
                body: "{\"email\":\"register-notes@slock.test\",\"password\":\"password123\",\"name\":\"notes\",\(legal)}"
            )
            #expect(allowed.status == .ok)
            #expect(accounts.hasAccount(email: "register-notes@slock.test"))
            #expect(accounts.sessionCount == before + 1)
        }
    }
}

@Test func registerAcceptsDuplicateFinalHandlesAsPendingAccounts() async throws {
    let accounts = EmailLoginDirectory()
    let username = "exact-race-ab12cd34"
    let legal = "\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\""
    let before = (
        accounts.userCount,
        accounts.legalAcceptanceCount,
        accounts.emailVerificationCount,
        accounts.sessionCount
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func register(_ email: String, name: String) async throws -> ClientResponse {
                try await registerJSON(
                    client,
                    body: "{\"email\":\"\(email)\",\"password\":\"password123\",\"name\":\"\(name)\",\(legal)}"
                )
            }
            let first = try await register("exact-race-a@slock.test", name: username)
            let second = try await register("exact-race-b@slock.test", name: username)
            #expect(first.status == .ok)
            #expect(second.status == .ok)
            let firstUser = ((try JSONSerialization.jsonObject(with: Data(bodyText(first).utf8)) as? [String: Any])?["user"] as? [String: Any]) ?? [:]
            let secondUser = ((try JSONSerialization.jsonObject(with: Data(bodyText(second).utf8)) as? [String: Any])?["user"] as? [String: Any]) ?? [:]
            let firstId = firstUser["id"] as? String ?? ""
            let secondId = secondUser["id"] as? String ?? ""
            #expect(firstId.isEmpty == false)
            #expect(secondId.isEmpty == false)
            #expect(firstId != secondId)
            let pending = /^pending_[0-9a-f]{20}$/
            #expect((firstUser["name"] as? String)?.wholeMatch(of: pending) != nil)
            #expect((secondUser["name"] as? String)?.wholeMatch(of: pending) != nil)
            #expect(firstUser["name"] as? String != secondUser["name"] as? String)
            #expect(firstUser["profileSetupCompletedAt"] is NSNull)
            #expect(secondUser["profileSetupCompletedAt"] is NSNull)
            #expect((firstUser["profileSetupSuggestedHandle"] as? String)?.hasPrefix(username) == true)
            #expect((secondUser["profileSetupSuggestedHandle"] as? String)?.hasPrefix(username) == true)
            #expect(accounts.userCount == before.0 + 2)
            #expect(accounts.legalAcceptanceCount == before.1 + 2)
            #expect(accounts.emailVerificationCount == before.2 + 2)
            #expect(accounts.sessionCount == before.3 + 2)
        }
    }
}

@Test func registerPreservesCaseSensitiveUsernameUniqueness() async throws {
    let accounts = EmailLoginDirectory()
    let suffix = "ab12cd34"
    let legal = "\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\""
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let lower = try await registerJSON(
                client,
                body: "{\"email\":\"case-lower-\(suffix)@slock.test\",\"password\":\"password123\",\"name\":\"case-\(suffix)\",\(legal)}"
            )
            let upper = try await registerJSON(
                client,
                body: "{\"email\":\"case-upper-\(suffix)@slock.test\",\"password\":\"password123\",\"name\":\"Case-\(suffix)\",\(legal)}"
            )
            #expect(lower.status == .ok)
            #expect(upper.status == .ok)
        }
    }
}

@Test func socialFirstLoginRequiresLegalAcceptance() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addSocialCompletion(
        provider: "google",
        code: "google-legal-code",
        email: "google-legal@slock.test",
        returnTo: "/"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let missing = try await postJSON(
                client,
                "/api/auth/google/complete",
                body: "{\"code\":\"google-legal-code\"}"
            )
            #expect(missing.status == .unprocessableContent)
            #expect(accounts.hasAccount(email: "google-legal@slock.test") == false)
            #expect(accounts.sessionCount == 0)
            #expect(accounts.legalAcceptanceCount == 0)

            let accepted = try await postJSON(
                client,
                "/api/auth/google/complete",
                body: "{\"code\":\"google-legal-code\",\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\"}"
            )
            #expect(accepted.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(accepted).utf8)) as? [String: Any]
            let accessToken = body?["accessToken"] as? String ?? ""
            let refreshToken = body?["refreshToken"] as? String ?? ""
            #expect(accessToken.isEmpty == false)
            #expect(refreshToken.isEmpty == false)
            #expect(accounts.hasAccount(email: "google-legal@slock.test"))
            let userId = accounts.userId(forEmail: "google-legal@slock.test") ?? ""
            #expect(accounts.legalAcceptance(userId: userId)?.source == "oauth")
            #expect(accounts.legalAcceptance(userId: userId)?.termsVersion == "2026-05-12")
            #expect(accounts.sessionCount == 1)
        }
    }
}

@Test func webSocialCompletionStaysWebShapedAndSpendsTheCode() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "66666666-6666-4666-8666-666666666666"
    accounts.addAccount(id: userId, email: "web-unified@slock.test", password: "password123")
    accounts.addSocialCompletion(
        provider: "google",
        code: "google-web-unified-code",
        email: "web-unified@slock.test",
        returnTo: "/s/dev",
        userId: userId
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let complete = try await postJSON(
                client,
                "/api/auth/google/complete",
                body: "{\"code\":\"google-web-unified-code\"}"
            )
            #expect(complete.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(complete).utf8)) as? [String: Any]
            #expect(body?["provider"] as? String == "google")
            #expect(body?["mode"] as? String == "login")
            #expect(body?["returnTo"] as? String == "/s/dev")
            let accessToken = body?["accessToken"] as? String ?? ""
            let refreshToken = body?["refreshToken"] as? String ?? ""
            #expect(accessToken.isEmpty == false)
            #expect(refreshToken.isEmpty == false)

            let me = try await client.get("/api/auth/me", headers: [
                HTTPField.Name("Authorization")!: "Bearer \(accessToken)",
            ])
            #expect(me.status == .ok)
            let meBody = try JSONSerialization.jsonObject(with: Data(bodyText(me).utf8)) as? [String: Any]
            #expect(meBody?["id"] as? String == userId)

            let spent = try await postJSON(
                client,
                "/api/auth/google/complete",
                body: "{\"code\":\"google-web-unified-code\"}"
            )
            #expect(spent.status == .badRequest)
            #expect(bodyText(spent) == "{\"error\":\"Invalid or expired social auth completion\"}")
        }
    }
}

private func postAuthorized(_ client: any Client, _ path: String, token: String?, body: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let token {
        headers[HTTPField.Name("Authorization")!] = "Bearer \(token)"
    }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

@Test func webLinkCompletionIsOwnerBoundAndOneTime() async throws {
    let accounts = EmailLoginDirectory()
    let otherId = "77777777-7777-4777-8777-777777777777"
    accounts.addAccount(id: otherId, email: "web-link-other@slock.test", password: "password123")
    let owners = [
        ("google", "88888888-8888-4888-8888-888888888888"),
        ("github", "99999999-9999-4999-8999-999999999999"),
    ]
    for (provider, userId) in owners {
        accounts.addAccount(id: userId, email: "\(provider)-web-link-race@slock.test", password: "password123")
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let otherLogin = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"web-link-other@slock.test\",\"password\":\"password123\"}"
            )
            let otherToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(otherLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            for (provider, userId) in owners {
                let providerUserId = "\(provider)-web-link-race-provider-id"
                let code = "\(provider)-web-link-code"
                accounts.addSocialCompletion(
                    provider: provider,
                    code: code,
                    email: "\(provider)-web-link-race-social@slock.test",
                    mode: "link",
                    intendedAction: "link",
                    returnTo: "/settings?tab=account",
                    userId: userId,
                    providerUserId: providerUserId
                )
                let ownerLogin = try await postJSON(
                    client,
                    "/api/auth/login",
                    body: "{\"email\":\"\(provider)-web-link-race@slock.test\",\"password\":\"password123\"}"
                )
                let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
                let sessionsBefore = accounts.sessionCount
                let path = "/api/auth/\(provider)/complete"
                let body = "{\"code\":\"\(code)\"}"

                let missing = try await postAuthorized(client, path, token: nil, body: body)
                #expect(missing.status == .unauthorized)
                let missingBody = try JSONSerialization.jsonObject(with: Data(bodyText(missing).utf8)) as? [String: Any]
                #expect(missingBody?["code"] as? String == "auth_required")
                #expect(accounts.linkedProviderUserIds(userId: userId, provider: provider).isEmpty)

                let wrong = try await postAuthorized(client, path, token: otherToken, body: body)
                #expect(wrong.status == .forbidden)
                let wrongBody = try JSONSerialization.jsonObject(with: Data(bodyText(wrong).utf8)) as? [String: Any]
                #expect(wrongBody?["code"] as? String == "link_user_mismatch")
                #expect(accounts.linkedProviderUserIds(userId: userId, provider: provider).isEmpty)

                let first = try await postAuthorized(client, path, token: ownerToken, body: body)
                let second = try await postAuthorized(client, path, token: ownerToken, body: body)
                #expect([first.status.code, second.status.code].sorted() == [200, 400])
                let winner = first.status == .ok ? first : second
                let winnerBody = try JSONSerialization.jsonObject(with: Data(bodyText(winner).utf8)) as? [String: Any]
                #expect(winnerBody?["mode"] as? String == "link")
                #expect(winnerBody?["accessToken"] == nil)
                #expect(winnerBody?["refreshToken"] == nil)
                #expect(accounts.linkedProviderUserIds(userId: userId, provider: provider) == [providerUserId])
                #expect(accounts.sessionCount == sessionsBefore)
            }
        }
    }
}

@Test func webLinkCompletionSurvivesAnExpiredAccessTokenAfterOneRefresh() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    accounts.addAccount(id: userId, email: "web-link-refresh@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"web-link-refresh@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let loginBody = try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any]
            let refreshToken = loginBody?["refreshToken"] as? String ?? ""
            #expect(refreshToken.isEmpty == false)

            let code = "github-web-link-refresh-code"
            accounts.addSocialCompletion(
                provider: "github",
                code: code,
                email: "github-web-link-refresh-social@slock.test",
                mode: "link",
                intendedAction: "link",
                returnTo: "/settings?tab=account",
                userId: userId,
                providerUserId: "github-web-link-refresh-provider-id"
            )
            let expired = try await postAuthorized(
                client,
                "/api/auth/github/complete",
                token: "expired-access-token",
                body: "{\"code\":\"\(code)\"}"
            )
            #expect(expired.status == .unauthorized)
            let expiredBody = try JSONSerialization.jsonObject(with: Data(bodyText(expired).utf8)) as? [String: Any]
            #expect(expiredBody?["code"] as? String == "auth_required")
            #expect(accounts.linkedProviderUserIds(userId: userId, provider: "github").isEmpty)

            let refresh = try await postJSON(
                client,
                "/api/auth/refresh",
                body: "{\"refreshToken\":\"\(refreshToken)\"}"
            )
            #expect(refresh.status == .ok)
            let refreshBody = try JSONSerialization.jsonObject(with: Data(bodyText(refresh).utf8)) as? [String: Any]
            let accessToken = refreshBody?["accessToken"] as? String ?? ""
            #expect(accessToken.isEmpty == false)
            #expect(accessToken != "expired-access-token")

            let completed = try await postAuthorized(
                client,
                "/api/auth/github/complete",
                token: accessToken,
                body: "{\"code\":\"\(code)\"}"
            )
            #expect(completed.status == .ok)
            #expect(accounts.linkedProviderUserIds(userId: userId, provider: "github") == ["github-web-link-refresh-provider-id"])
        }
    }
}

private func refreshBound(
    _ client: any Client,
    token: String,
    attempt: String? = nil,
    installation: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let attempt {
        headers[HTTPField.Name("X-Slock-Auth-Refresh-Attempt-Id")!] = attempt
    }
    if let installation {
        headers[HTTPField.Name("X-Slock-Auth-Installation-Id")!] = installation
    }
    return try await client.send(.post, headers: headers, to: URI(string: "/api/auth/refresh")) { request in
        request.body = .init(string: "{\"refreshToken\":\"\(token)\"}")
    }
}

@Test func durableRefreshReplayReturnsOneSuccessorForTheExactBinding() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", email: "durable-refresh@slock.test", password: "password123")
    let attempt = "arf_1234567890abcdef"
    let installation = "ari_1234567890abcdef1234567890abcdef"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"durable-refresh@slock.test\",\"password\":\"password123\"}"
            )
            let predecessor = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["refreshToken"] as? String) ?? ""
            #expect(predecessor.isEmpty == false)

            let first = try await refreshBound(client, token: predecessor, attempt: attempt, installation: installation)
            let second = try await refreshBound(client, token: predecessor, attempt: attempt, installation: installation)
            #expect(first.status == .ok)
            #expect(second.status == .ok)
            let firstToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(first).utf8)) as? [String: Any])?["refreshToken"] as? String) ?? ""
            let secondToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(second).utf8)) as? [String: Any])?["refreshToken"] as? String) ?? ""
            #expect(firstToken.isEmpty == false)
            #expect(secondToken == firstToken)
            #expect(firstToken != predecessor)

            let retry = try await refreshBound(client, token: predecessor, attempt: attempt, installation: installation)
            #expect(retry.status == .ok)
            let retryToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(retry).utf8)) as? [String: Any])?["refreshToken"] as? String) ?? ""
            #expect(retryToken == firstToken)

            let receipt = accounts.refreshRotationReceipts().first
            #expect(receipt?.attemptId == attempt)
            #expect(receipt?.installationId == installation)
            #expect(receipt?.successorTokenCiphertext != firstToken)
            #expect(receipt?.successorTokenCiphertext.contains(firstToken) == false)

            let wrongAttempt = try await refreshBound(client, token: predecessor, attempt: "arf_fedcba0987654321", installation: installation)
            #expect(wrongAttempt.status == .unauthorized)
            let wrongInstallation = try await refreshBound(
                client,
                token: predecessor,
                attempt: attempt,
                installation: "ari_fedcba0987654321fedcba0987654321"
            )
            #expect(wrongInstallation.status == .unauthorized)
            let omitted = try await refreshBound(client, token: predecessor)
            #expect(omitted.status == .unauthorized)
            #expect((try await refreshBound(client, token: predecessor, attempt: attempt, installation: installation)).status == .ok)

            let logout = try await postJSON(client, "/api/auth/logout", body: "{\"refreshToken\":\"\(predecessor)\"}")
            #expect(logout.status == .ok)
            #expect((try await refreshBound(client, token: predecessor, attempt: attempt, installation: installation)).status == .unauthorized)
        }
    }
}

@Test func durableRefreshReplayRejectsAMalformedBindingWithoutConsumingThePredecessor() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", email: "durable-refresh-expiry@slock.test", password: "password123")
    let attempt = "arf_0011223344556677"
    let installation = "ari_00112233445566778899aabbccddeeff"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                "/api/auth/login",
                body: "{\"email\":\"durable-refresh-expiry@slock.test\",\"password\":\"password123\"}"
            )
            let predecessor = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["refreshToken"] as? String) ?? ""
            let malformed = try await refreshBound(client, token: predecessor, attempt: attempt, installation: "ari_not-an-installation")
            #expect(malformed.status == .badRequest)
            #expect(bodyText(malformed) == "{\"error\":\"Invalid refresh replay binding\"}")

            let first = try await refreshBound(client, token: predecessor, attempt: attempt, installation: installation)
            #expect(first.status == .ok)

            accounts.expireRefreshReceipts()
            let expired = try await refreshBound(client, token: predecessor, attempt: attempt, installation: installation)
            #expect(expired.status == .unauthorized)
        }
    }
}

@Test func desktopLoopbackCallbackRejectsAMismatchedNonce() async throws {
    let accounts = EmailLoginDirectory()
    let returnUri = "http://127.0.0.1:49152/auth/done#state=desktop_nonce_0123456789abcdef"
    let challenge = "5LKOfGgtJZKyKP401NWdx2aQeOjxPA2yKFhKPS3P_jg"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"\(returnUri)\",\"codeChallenge\":\"\(challenge)\"}"
            )
            #expect(start.status == .created)
            let startBody = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = startBody?["requestId"] as? String ?? ""
            let authorizationUrl = startBody?["authorizationUrl"] as? String ?? ""
            #expect(requestId.isEmpty == false)
            let state = URLComponents(string: authorizationUrl)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            let original = AuthTokenCodec.verifySocialAuthState(state)
            #expect(original?.desktopNonce == "desktop_nonce_0123456789abcdef")
            let tampered = AuthTokenCodec.signSocialAuthState(SocialAuthState(
                provider: original?.provider ?? "",
                mode: original?.mode ?? "",
                nonce: original?.nonce ?? "",
                kind: original?.kind ?? "",
                mobileRequestId: original?.mobileRequestId ?? "",
                desktopNonce: "different_nonce_0123456789abcdef"
            ))
            let encoded = tampered.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tampered
            let callback = try await client.get(URI(string: "/api/auth/google/callback?code=provider-code&state=\(encoded)"))
            #expect(callback.status == .badRequest)
            #expect(bodyText(callback) == "Invalid mobile OAuth request")
            #expect(accounts.providerExchangeCount == 0)
            #expect(accounts.oauthRequestStatus(id: requestId) == "pending_provider")
        }
    }
}

@Test func desktopLoopbackPreservesStateThroughOneTimePKCEComplete() async throws {
    let accounts = EmailLoginDirectory()
    let desktopState = "desktop_nonce_0123456789abcdef"
    let returnUri = "http://127.0.0.1:49152/auth/done#state=\(desktopState)"
    let verifier = "mobile-login-verifier-0123456789"
    let challenge = "BMiEvmoBGmnhU8L_jWsCA7aj93_oMgdoPJeSV44gETs"
    accounts.mobileProviderProfile = MobileProviderProfile(
        providerUserId: "google-mobile-user",
        email: "mobile-login@slock.test",
        displayName: "Mobile Login"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"\(returnUri)\",\"codeChallenge\":\"\(challenge)\"}"
            )
            #expect(start.status == .created)
            let startBody = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = startBody?["requestId"] as? String ?? ""
            #expect(startBody?["returnUri"] as? String == returnUri)
            #expect(accounts.oauthRequestReturnUri(id: requestId) == returnUri)
            let authorizationUrl = startBody?["authorizationUrl"] as? String ?? ""
            #expect(URL(string: authorizationUrl)?.host == "accounts.google.com")
            let state = URLComponents(string: authorizationUrl)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            #expect(AuthTokenCodec.verifySocialAuthState(state)?.desktopNonce == desktopState)

            let encoded = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
            let callback = try await client.get(URI(string: "/api/auth/google/callback?code=provider-code&state=\(encoded)"))
            #expect(callback.status == .found)
            let location = callback.headers[.location] ?? ""
            let returned = URL(string: location)
            #expect(returned?.scheme == "http")
            #expect(returned?.host == "127.0.0.1")
            #expect(returned?.path == "/auth/done")
            #expect(returned?.fragment == "state=\(desktopState)")
            let handoff = URLComponents(string: location)?.queryItems?.first { $0.name == "code" }?.value ?? ""
            #expect(handoff.isEmpty == false)

            let browser = try await postJSON(client, "/api/auth/google/complete", body: "{\"code\":\"\(handoff)\"}")
            #expect(browser.status == .badRequest)
            #expect(accounts.oauthRequestStatus(id: requestId) == "provider_completed")
            #expect((accounts.oauthRequestCodeHash(id: requestId) ?? "").isEmpty == false)

            let complete = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\",\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\"}"
            )
            #expect(complete.status == .ok)
            let completeBody = try JSONSerialization.jsonObject(with: Data(bodyText(complete).utf8)) as? [String: Any]
            let user = completeBody?["user"] as? [String: Any]
            #expect(user?["email"] as? String == "mobile-login@slock.test")
            #expect((user?["name"] as? String)?.wholeMatch(of: /^pending_[0-9a-f]{20}$/) != nil)
            #expect(user?["profileSetupCompletedAt"] is NSNull)
            #expect(user?["profileSetupProvider"] as? String == "google")
            #expect((completeBody?["accessToken"] as? String)?.isEmpty == false)
            #expect((completeBody?["refreshToken"] as? String)?.isEmpty == false)
            #expect(completeBody?["mode"] as? String == "login")
            #expect(completeBody?["returnUri"] as? String == returnUri)
            #expect(accounts.userId(forEmail: "mobile-login@slock.test") == user?["id"] as? String)

            let replay = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\"}"
            )
            #expect(replay.status == .gone)
            let replayBody = try JSONSerialization.jsonObject(with: Data(bodyText(replay).utf8)) as? [String: Any]
            #expect(replayBody?["code"] as? String == "handoff_code_consumed")
            #expect(accounts.oauthRequestStatus(id: requestId) == "completed")
        }
    }
}

@Test func mobileOAuthLegalRetryKeepsTheHandoffUntilAcceptance() async throws {
    let accounts = EmailLoginDirectory()
    let verifier = "mobile-legal-retry-verifier-123456789"
    let challenge = "viYOYKFe73Jfjd-lIqh-6exlc2DFxMKVZ3DSeezDDvE"
    accounts.mobileProviderProfile = MobileProviderProfile(
        providerUserId: "google-mobile-legal-retry-user",
        email: "mobile-legal-retry@slock.test",
        displayName: "Mobile Legal Retry"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"\(challenge)\"}"
            )
            #expect(start.status == .created)
            let startBody = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = startBody?["requestId"] as? String ?? ""
            #expect(accounts.oauthRequestStatus(id: requestId) == "pending_provider")
            #expect(accounts.oauthRequestCodeHash(id: requestId) == nil)
            #expect(accounts.oauthRequestCodeChallenge(id: requestId) == challenge)

            let state = URLComponents(string: startBody?["authorizationUrl"] as? String ?? "")?.queryItems?.first { $0.name == "state" }?.value ?? ""
            let encoded = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
            let callback = try await client.get(URI(string: "/api/auth/google/callback?code=provider-code&state=\(encoded)"))
            #expect(callback.status == .found)
            let handoff = URLComponents(string: callback.headers[.location] ?? "")?.queryItems?.first { $0.name == "code" }?.value ?? ""
            #expect(handoff.isEmpty == false)

            let missing = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\"}"
            )
            #expect(missing.status == .unprocessableContent)
            let missingBody = try JSONSerialization.jsonObject(with: Data(bodyText(missing).utf8)) as? [String: Any]
            #expect(missingBody?["error"] as? String == "LEGAL_ACCEPTANCE_REQUIRED")
            #expect(accounts.hasAccount(email: "mobile-legal-retry@slock.test") == false)
            #expect(accounts.oauthRequestStatus(id: requestId) == "provider_completed")
            #expect((accounts.oauthRequestCodeHash(id: requestId) ?? "").isEmpty == false)

            let accepted = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\",\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\"}"
            )
            #expect(accepted.status == .ok)
            let acceptedBody = try JSONSerialization.jsonObject(with: Data(bodyText(accepted).utf8)) as? [String: Any]
            let user = acceptedBody?["user"] as? [String: Any]
            #expect(user?["email"] as? String == "mobile-legal-retry@slock.test")
            #expect((acceptedBody?["accessToken"] as? String)?.isEmpty == false)
            #expect((acceptedBody?["refreshToken"] as? String)?.isEmpty == false)
            #expect(accounts.oauthRequestStatus(id: requestId) == "completed")

            let replay = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\"}"
            )
            #expect(replay.status == .gone)
            let replayBody = try JSONSerialization.jsonObject(with: Data(bodyText(replay).utf8)) as? [String: Any]
            #expect(replayBody?["code"] as? String == "handoff_code_consumed")
        }
    }
}

@Test func mobileGitHubLoginCompletesThroughTheSharedHandoff() async throws {
    let accounts = EmailLoginDirectory()
    let verifier = "mobile-github-verifier-0123456789"
    let challenge = "KeTxTublYElkrWm49I19Vug4vLodnrsob_5iOTahN1E"
    accounts.mobileProviderProfile = MobileProviderProfile(
        providerUserId: "98765",
        email: "mobile-github@slock.test",
        displayName: "GitHub Mobile"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"github\",\"mode\":\"login\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"\(challenge)\"}"
            )
            #expect(start.status == .created)
            let startBody = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let authorizationUrl = startBody?["authorizationUrl"] as? String ?? ""
            #expect(URL(string: authorizationUrl)?.host == "github.com")
            let state = URLComponents(string: authorizationUrl)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            let encoded = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
            let callback = try await client.get(URI(string: "/api/auth/github/callback?code=provider-code&state=\(encoded)"))
            #expect(callback.status == .found)
            let handoff = URLComponents(string: callback.headers[.location] ?? "")?.queryItems?.first { $0.name == "code" }?.value ?? ""
            #expect(handoff.isEmpty == false)

            let complete = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\",\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\"}"
            )
            #expect(complete.status == .ok)
            let completeBody = try JSONSerialization.jsonObject(with: Data(bodyText(complete).utf8)) as? [String: Any]
            let user = completeBody?["user"] as? [String: Any]
            let userId = user?["id"] as? String ?? ""
            #expect(user?["email"] as? String == "mobile-github@slock.test")
            #expect((user?["name"] as? String)?.wholeMatch(of: /^pending_[0-9a-f]{20}$/) != nil)
            #expect(user?["profileSetupCompletedAt"] is NSNull)
            #expect(user?["profileSetupProvider"] as? String == "github")
            #expect((completeBody?["accessToken"] as? String)?.isEmpty == false)
            let refreshToken = completeBody?["refreshToken"] as? String ?? ""
            #expect(refreshToken.isEmpty == false)
            #expect(completeBody?["mode"] as? String == "login")
            #expect(accounts.userId(forEmail: "mobile-github@slock.test") == userId)
            #expect(accounts.linkedProviderUserIds(userId: userId, provider: "github") == ["98765"])

            let refresh = try await postJSON(client, "/api/auth/refresh", body: "{\"refreshToken\":\"\(refreshToken)\"}")
            #expect(refresh.status == .ok)
            let accessToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(refresh).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let me = try await client.get("/api/auth/me", headers: [
                HTTPField.Name("Authorization")!: "Bearer \(accessToken)",
            ])
            #expect(me.status == .ok)
            let meBody = try JSONSerialization.jsonObject(with: Data(bodyText(me).utf8)) as? [String: Any]
            #expect((meBody?["name"] as? String)?.wholeMatch(of: /^pending_[0-9a-f]{20}$/) != nil)
            #expect(meBody?["profileSetupCompletedAt"] is NSNull)
            #expect(meBody?["profileSetupProvider"] as? String == "github")
        }
    }
}

@Test func mobileOAuthStartRejectsADisabledReturnTarget() async throws {
    let accounts = EmailLoginDirectory()
    let before = accounts.mobileOAuthRequestCount
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"https://evil.example.test/oauth/callback\",\"codeChallenge\":\"aJx2vZf5lDZVZ2tbYZpHRNK0uL5OcsFq_RV25ZoVL38\"}"
            )
            #expect(start.status == .badRequest)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            #expect(body?["code"] as? String == "return_uri_not_allowed")
            #expect(body?["error"] as? String == "Mobile OAuth return URI is not allowed")
            #expect(accounts.mobileOAuthRequestCount == before)
        }
    }
}

@Test func mobileOAuthStartFallsBackToLegacyAllowedReturnURIs() async throws {
    let accounts = EmailLoginDirectory()
    accounts.mobileOAuthAllowedReturnURIs = "raft-legacy://oauth/callback"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"raft-legacy://oauth/callback\",\"codeChallenge\":\"nuDnGulalhDxW9YRPiuruLpLL5J1QD9CqzsJBj2ykNg\"}"
            )
            #expect(start.status == .created)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            #expect(body?["returnUri"] as? String == "raft-legacy://oauth/callback")
            #expect(accounts.mobileOAuthRequestCount == 1)

            let disabledDefault = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"Kb9EbPFAKM9RTrLS8SGf7Ap0aWkiGaxeDJhG57T2HkM\"}"
            )
            #expect(disabledDefault.status == .badRequest)
            let refused = try JSONSerialization.jsonObject(with: Data(bodyText(disabledDefault).utf8)) as? [String: Any]
            #expect(refused?["code"] as? String == "return_uri_not_allowed")
            #expect(accounts.mobileOAuthRequestCount == 1)
        }
    }
}

@Test func mobileOAuthStartAcceptsAnAllowlistedVariantReturnURI() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"raft-beta://oauth/callback\",\"codeChallenge\":\"lKdHD_9wChYlGGEh8bUpjER_zaj7mU43VNX1Fz1oCKw\"}"
            )
            #expect(start.status == .created)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            #expect(body?["returnUri"] as? String == "raft-beta://oauth/callback")
            #expect(accounts.mobileOAuthRequestCount == 1)

            let missing = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"codeChallenge\":\"yDfJa9FSq1cnozDgZr6VnTEBRxkAuV17oYGNKtKQTz0\"}"
            )
            #expect(missing.status == .badRequest)
            let refused = try JSONSerialization.jsonObject(with: Data(bodyText(missing).utf8)) as? [String: Any]
            #expect(refused?["code"] as? String == "return_uri_not_allowed")
            #expect(accounts.mobileOAuthRequestCount == 1)
        }
    }
}

@Test func mobileOAuthProviderCancelReturnsAppErrorAndFailedState() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"5GxWEsk3tULK4iY4mv4oYwFx7RezVoKXglWWSu8oJTs\"}"
            )
            #expect(start.status == .created)
            let startBody = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = startBody?["requestId"] as? String ?? ""
            let authorizationUrl = startBody?["authorizationUrl"] as? String ?? ""
            let state = URLComponents(string: authorizationUrl)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            let encoded = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
            let callback = try await client.get(URI(string: "/api/auth/google/callback?error=access_denied&state=\(encoded)"))
            #expect(callback.status == .found)
            let location = callback.headers[.location] ?? ""
            let returned = URLComponents(string: location)
            #expect(returned?.queryItems?.first { $0.name == "error" }?.value == "access_denied")
            #expect(accounts.oauthRequestStatus(id: requestId) == "failed")
            #expect(accounts.providerExchangeCount == 0)
        }
    }
}

@Test func mobileOAuthProviderExchangeFailureReturnsAppErrorWithoutWebFallback() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"kH4a86KFceN19v0Gg1VlquKU80SUjSaFCckaMWSoYyg\"}"
            )
            #expect(start.status == .created)
            let startBody = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = startBody?["requestId"] as? String ?? ""
            let authorizationUrl = startBody?["authorizationUrl"] as? String ?? ""
            let state = URLComponents(string: authorizationUrl)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            let encoded = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
            let callback = try await client.get(URI(string: "/api/auth/google/callback?code=bad-provider-code&state=\(encoded)"))
            #expect(callback.status == .found)
            let location = callback.headers[.location] ?? ""
            let returned = URL(string: location)
            #expect(returned?.scheme == "raft-debug")
            #expect(returned?.host == "oauth")
            #expect(returned?.path == "/callback")
            #expect(URLComponents(string: location)?.queryItems?.first { $0.name == "error" }?.value == "provider_exchange_failed")
            #expect(accounts.oauthRequestStatus(id: requestId) == "failed")
            #expect(accounts.providerExchangeCount == 0)
        }
    }
}

@Test func mobileOAuthInvalidMobileStateFailsClosedWithoutWebCallbackRedirect() async throws {
    let accounts = EmailLoginDirectory()
    let state = AuthTokenCodec.signSocialAuthState(SocialAuthState(
        provider: "google",
        mode: "login",
        nonce: "nonce",
        kind: "mobile",
        mobileRequestId: UUID().uuidString.lowercased(),
        desktopNonce: nil
    ))
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let encoded = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
            let callback = try await client.get(URI(string: "/api/auth/google/callback?code=provider-code&state=\(encoded)"))
            #expect(callback.status == .badRequest)
            #expect(bodyText(callback) == "Invalid mobile OAuth request")
            #expect((callback.headers[.location] ?? "").isEmpty)
        }
    }
}

@Test func mobileOAuthCompleteRejectsAnExpiredHandoffCode() async throws {
    let accounts = EmailLoginDirectory()
    accounts.mobileProviderProfile = MobileProviderProfile(
        providerUserId: "google-expired-user",
        email: "mobile-expired@slock.test",
        displayName: nil
    )
    let verifier = "mobile-expired-verifier-123456789"
    let challenge = "tyoDKplpRXmNygAOoca3G-1C_aiyWZI4zVOsAKtGJYc"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"\(challenge)\"}"
            )
            #expect(start.status == .created)
            let startBody = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = startBody?["requestId"] as? String ?? ""
            let authorizationUrl = startBody?["authorizationUrl"] as? String ?? ""
            let state = URLComponents(string: authorizationUrl)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            let encoded = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
            let callback = try await client.get(URI(string: "/api/auth/google/callback?code=provider-code&state=\(encoded)"))
            #expect(callback.status == .found)
            let location = callback.headers[.location] ?? ""
            let handoff = URLComponents(string: location)?.queryItems?.first { $0.name == "code" }?.value ?? ""
            #expect(handoff.isEmpty == false)

            accounts.expireMobileOAuthRequest(id: requestId)
            let complete = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\"}"
            )
            #expect(complete.status == .gone)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(complete).utf8)) as? [String: Any]
            #expect(body?["code"] as? String == "handoff_code_expired")
            #expect(body?["error"] as? String == "Mobile OAuth code has expired")
            #expect(accounts.userId(forEmail: "mobile-expired@slock.test") == nil)
            #expect(accounts.oauthRequestStatus(id: requestId) == "expired")
        }
    }
}

@Test func mobileOAuthCompleteRejectsAPKCEMismatchWithoutASession() async throws {
    let accounts = EmailLoginDirectory()
    accounts.mobileProviderProfile = MobileProviderProfile(
        providerUserId: "google-pkce-user",
        email: "mobile-pkce@slock.test",
        displayName: nil
    )
    let challenge = "Q1VLNyMseH2O2jx7a8w2tjzHSz7ks8mqmAddCAiCnRs"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"\(challenge)\"}"
            )
            #expect(start.status == .created)
            let startBody = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = startBody?["requestId"] as? String ?? ""
            let authorizationUrl = startBody?["authorizationUrl"] as? String ?? ""
            let state = URLComponents(string: authorizationUrl)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            let encoded = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
            let callback = try await client.get(URI(string: "/api/auth/google/callback?code=provider-code&state=\(encoded)"))
            #expect(callback.status == .found)
            let location = callback.headers[.location] ?? ""
            let handoff = URLComponents(string: location)?.queryItems?.first { $0.name == "code" }?.value ?? ""

            let complete = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"wrong-verifier-123456789\"}"
            )
            #expect(complete.status == .badRequest)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(complete).utf8)) as? [String: Any]
            #expect(body?["code"] as? String == "pkce_mismatch")
            #expect(body?["error"] as? String == "PKCE verifier did not match the OAuth request")
            #expect(accounts.userId(forEmail: "mobile-pkce@slock.test") == nil)
            #expect(accounts.sessionCount == 0)
            #expect(accounts.oauthRequestStatus(id: requestId) == "failed")
        }
    }
}

@Test func mobileOAuthLinkRequiresABearerAndLinksTheOwnerWithoutALoginSession() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111111"
    let otherId = "22222222-2222-4222-8222-222222222222"
    accounts.addAccount(id: ownerId, email: "mobile-link-owner@slock.test", password: "password123")
    accounts.addAccount(id: otherId, email: "mobile-link-other@slock.test", password: "password123")
    accounts.mobileProviderProfile = MobileProviderProfile(
        providerUserId: "google-link-user",
        email: "mobile-link-social@slock.test",
        displayName: nil
    )
    let verifier = "mobile-link-verifier-123456789"
    let challenge = "iIBndehIqxMFMi6jj42QoGrh1vEHL8KrfaqF14grjKI"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"mobile-link-owner@slock.test\",\"password\":\"password123\"}")
            let otherLogin = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"mobile-link-other@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let otherToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(otherLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sessionsBefore = accounts.sessionCount
            let startBody = "{\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"\(challenge)\"}"

            let unauthenticated = try await postJSON(client, "/api/auth/mobile/oauth/google/link/start", body: startBody)
            #expect(unauthenticated.status == .unauthorized)
            let refused = try JSONSerialization.jsonObject(with: Data(bodyText(unauthenticated).utf8)) as? [String: Any]
            #expect(refused?["code"] as? String == "auth_required")
            #expect(refused?["error"] as? String == "Missing or invalid Authorization header")
            #expect(accounts.mobileOAuthRequestCount == 0)

            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/google/link/start",
                body: startBody,
                authorization: "Bearer \(ownerToken)"
            )
            #expect(start.status == .created)
            let started = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = started?["requestId"] as? String ?? ""
            let authorizationUrl = started?["authorizationUrl"] as? String ?? ""
            let state = URLComponents(string: authorizationUrl)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            let encoded = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
            let callback = try await client.get(URI(string: "/api/auth/google/callback?code=provider-code&state=\(encoded)"))
            #expect(callback.status == .found)
            let location = callback.headers[.location] ?? ""
            let items = URLComponents(string: location)?.queryItems ?? []
            #expect(items.first { $0.name == "provider" }?.value == "google")
            #expect(items.first { $0.name == "mode" }?.value == "link")
            let handoff = items.first { $0.name == "code" }?.value ?? ""
            #expect(handoff.isEmpty == false)

            let mismatch = try await postJSON(
                client,
                "/api/auth/mobile/oauth/google/link/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\"}",
                authorization: "Bearer \(otherToken)"
            )
            #expect(mismatch.status == .forbidden)
            let mismatchBody = try JSONSerialization.jsonObject(with: Data(bodyText(mismatch).utf8)) as? [String: Any]
            #expect(mismatchBody?["code"] as? String == "link_user_mismatch")
            #expect(mismatchBody?["error"] as? String == "Mobile OAuth link request does not match the authenticated user")
            #expect(accounts.oauthRequestStatus(id: requestId) == "provider_completed")
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "google").isEmpty)

            let ok = try await postJSON(
                client,
                "/api/auth/mobile/oauth/google/link/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\"}",
                authorization: "Bearer \(ownerToken)"
            )
            #expect(ok.status == .ok)
            let okBody = try JSONSerialization.jsonObject(with: Data(bodyText(ok).utf8)) as? [String: Any]
            #expect(okBody?["provider"] as? String == "google")
            #expect(okBody?["mode"] as? String == "link")
            #expect(okBody?["accessToken"] == nil)
            #expect(okBody?["refreshToken"] == nil)
            let identities = okBody?["identities"] as? [[String: Any]]
            #expect(identities?.count == 1)
            #expect(identities?.first?["provider"] as? String == "google")
            #expect(identities?.first?["providerEmail"] as? String == "mobile-link-social@slock.test")
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "google") == ["google-link-user"])
            #expect(accounts.linkedProviderUserIds(userId: otherId, provider: "google").isEmpty)
            #expect(accounts.sessionCount == sessionsBefore)
            #expect(accounts.userId(forEmail: "mobile-link-social@slock.test") == nil)
        }
    }
}

@Test func mobileOAuthLinkCompleteRejectsALoginHandoff() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "33333333-3333-4333-8333-333333333333"
    accounts.addAccount(id: ownerId, email: "mobile-link-mode-owner@slock.test", password: "password123")
    accounts.mobileProviderProfile = MobileProviderProfile(
        providerUserId: "google-login-mode-user",
        email: "mobile-link-login-mode@slock.test",
        displayName: nil
    )
    let verifier = "mobile-link-mode-verifier-123456789"
    let challenge = "mNM0WD-kylnNMf59CwY1Ws6_5vwBLe4NWm_SVk19CnI"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"mobile-link-mode-owner@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"google\",\"mode\":\"login\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"\(challenge)\"}"
            )
            #expect(start.status == .created)
            let started = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = started?["requestId"] as? String ?? ""
            let authorizationUrl = started?["authorizationUrl"] as? String ?? ""
            let state = URLComponents(string: authorizationUrl)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            let encoded = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? state
            let callback = try await client.get(URI(string: "/api/auth/google/callback?code=provider-code&state=\(encoded)"))
            #expect(callback.status == .found)
            let handoff = URLComponents(string: callback.headers[.location] ?? "")?.queryItems?.first { $0.name == "code" }?.value ?? ""

            let linkComplete = try await postJSON(
                client,
                "/api/auth/mobile/oauth/google/link/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\"}",
                authorization: "Bearer \(ownerToken)"
            )
            #expect(linkComplete.status == .badRequest)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(linkComplete).utf8)) as? [String: Any]
            #expect(body?["code"] as? String == "mode_mismatch")
            #expect(body?["error"] as? String == "Mobile OAuth code does not match the requested mode")
            #expect(accounts.userId(forEmail: "mobile-link-login-mode@slock.test") == nil)
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "google").isEmpty)
            #expect(accounts.oauthRequestStatus(id: requestId) == "provider_completed")
        }
    }
}

@Test func postCurrentUserAvatarStoresAUserWebpPath() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: "44444444-4444-4444-8444-444444444444", email: "human-avatar@slock.test", password: "password123")
    let gif = Data(base64Encoded: "R0lGODdhAQABAIABAP///wAAACwAAAAAAQABAAACAkQBADs=")!
    let upload = avatarMultipart(filename: "avatar.gif", mime: "image/gif", bytes: gif)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"human-avatar@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let posted = try await postBytes(client, "/api/auth/me/avatar", contentType: upload.contentType, body: upload.body, authorization: "Bearer \(token)")
            #expect(posted.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(posted).utf8)) as? [String: Any]
            let avatarURL = body?["avatarUrl"] as? String ?? ""
            #expect(avatarURL.wholeMatch(of: /^\/api\/avatars\/users\/[0-9a-f]+\.webp$/) != nil)

            let me = try await client.get("/api/auth/me", headers: [
                HTTPField.Name("Authorization")!: "Bearer \(token)",
            ])
            #expect(me.status == .ok)
            let meBody = try JSONSerialization.jsonObject(with: Data(bodyText(me).utf8)) as? [String: Any]
            #expect(meBody?["avatarUrl"] as? String == avatarURL)
        }
    }
}

@Test func postCurrentUserAvatarRejectsAnOversizedFile() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: "55555555-5555-4555-8555-555555555555", email: "human-avatar-large@slock.test", password: "password123")
    let limit = 5 * 1024 * 1024
    let upload = avatarMultipart(filename: "huge.png", mime: "image/png", bytes: Data(count: limit + 1))
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"human-avatar-large@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let posted = try await postBytes(client, "/api/auth/me/avatar", contentType: upload.contentType, body: upload.body, authorization: "Bearer \(token)")
            #expect(posted.status == .badRequest)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(posted).utf8)) as? [String: Any]
            #expect(body?["error"] as? String == "Avatar image must be 5 MB or smaller")
            #expect(body?["errorCode"] as? String == "PROFILE_AVATAR_TOO_LARGE")
            #expect(body?["maxBytes"] as? Int == limit)
        }
    }
}

@Test func patchShareUsageDataRoundTripsAndRotatesTheAnalyticsId() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "66666666-6666-4666-8666-666666666666"
    accounts.addAccount(id: userId, email: "share-usage-data@slock.test", password: "password123")
    let original = accounts.analyticsId(userId: userId)
    #expect((original ?? "").isEmpty == false)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"share-usage-data@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            let me = try await client.get("/api/auth/me", headers: headers)
            #expect(me.status == .ok)
            let meBody = try JSONSerialization.jsonObject(with: Data(bodyText(me).utf8)) as? [String: Any]
            #expect(meBody?["shareUsageData"] is NSNull)

            let turnedOn = try await patchJSON(client, token: token, body: "{\"shareUsageData\":true}")
            #expect(turnedOn.status == .ok)
            let onBody = try JSONSerialization.jsonObject(with: Data(bodyText(turnedOn).utf8)) as? [String: Any]
            #expect(onBody?["shareUsageData"] as? Bool == true)
            #expect(accounts.analyticsId(userId: userId) == original)

            let turnedOff = try await patchJSON(client, token: token, body: "{\"shareUsageData\":false}")
            #expect(turnedOff.status == .ok)
            let offBody = try JSONSerialization.jsonObject(with: Data(bodyText(turnedOff).utf8)) as? [String: Any]
            #expect(offBody?["shareUsageData"] as? Bool == false)
            #expect(accounts.analyticsId(userId: userId) == nil)

            let cleared = try await patchJSON(client, token: token, body: "{\"shareUsageData\":null}")
            #expect(cleared.status == .ok)
            let clearedBody = try JSONSerialization.jsonObject(with: Data(bodyText(cleared).utf8)) as? [String: Any]
            #expect(clearedBody?["shareUsageData"] is NSNull)
            #expect(accounts.analyticsId(userId: userId) == nil)

            let again = try await patchJSON(client, token: token, body: "{\"shareUsageData\":true}")
            #expect(again.status == .ok)
            let fresh = accounts.analyticsId(userId: userId)
            #expect((fresh ?? "").isEmpty == false)
            #expect(fresh != original)

            let invalid = try await patchJSON(client, token: token, body: "{\"shareUsageData\":\"yes\"}")
            #expect(invalid.status == .badRequest)
            #expect(accounts.analyticsId(userId: userId) == fresh)
        }
    }
}

@Test func authProvidersFollowTheApplePlatformGate() async throws {
    let accounts = EmailLoginDirectory()
    accounts.configuredSocialAuthProviders = ["google", "github", "apple"]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func appleEnabled(_ query: String = "") async throws -> Bool {
                let response = try await client.get(URI(string: "/api/auth/providers\(query)"))
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
                let providers = body?["providers"] as? [[String: Any]] ?? []
                return providers.first { $0["id"] as? String == "apple" }?["enabled"] as? Bool ?? true
            }

            #expect(try await appleEnabled() == false)
            #expect(try await appleEnabled("?platform=mobile") == false)
            #expect(try await appleEnabled("?platform=web") == false)

            let invalid = try await client.get(URI(string: "/api/auth/providers?platform=desktop"))
            #expect(invalid.status == .badRequest)
            let invalidBody = try JSONSerialization.jsonObject(with: Data(bodyText(invalid).utf8)) as? [String: Any]
            #expect(invalidBody?["code"] as? String == "platform_invalid")
            #expect(invalidBody?["error"] as? String == "platform must be web or mobile")

            accounts.allowAppleLogin(on: ["web"])
            #expect(try await appleEnabled() == true)
            #expect(try await appleEnabled("?platform=web") == true)
            #expect(try await appleEnabled("?platform=mobile") == false)

            accounts.allowAppleLogin(on: ["mobile"])
            #expect(try await appleEnabled("?platform=mobile") == true)

            let mobile = try await client.get(URI(string: "/api/auth/providers?platform=mobile"))
            let mobileBody = try JSONSerialization.jsonObject(with: Data(bodyText(mobile).utf8)) as? [String: Any]
            let providers = mobileBody?["providers"] as? [[String: Any]] ?? []
            #expect(providers.first { $0["id"] as? String == "google" }?["enabled"] as? Bool == true)
            #expect(providers.first { $0["id"] as? String == "github" }?["enabled"] as? Bool == true)
        }
    }
}

@Test func appleWebLoginStaysClosedUntilTheWebGateThenStartsFormPost() async throws {
    let accounts = EmailLoginDirectory()
    accounts.configuredSocialAuthProviders = ["apple"]
    accounts.appleClientId = "apple-client-id"
    accounts.serverURL = "https://api.example.test"
    accounts.addAccount(id: "77777777-7777-4777-8777-777777777777", email: "apple-link-owner@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"apple-link-owner@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""

            let providersBefore = try await client.get(URI(string: "/api/auth/providers"))
            let beforeBody = try JSONSerialization.jsonObject(with: Data(bodyText(providersBefore).utf8)) as? [String: Any]
            let beforeProviders = beforeBody?["providers"] as? [[String: Any]] ?? []
            #expect(beforeProviders.first { $0["id"] as? String == "apple" }?["enabled"] as? Bool == false)

            let startBefore = try await client.get(URI(string: "/api/auth/apple/start"))
            #expect(startBefore.status == .notFound)
            let linkBefore = try await postJSON(
                client,
                "/api/auth/apple/link/start",
                body: "{\"returnTo\":\"/settings\"}",
                authorization: "Bearer \(token)"
            )
            #expect(linkBefore.status == .notFound)

            accounts.allowAppleLogin(on: ["web"])

            let providersAfter = try await client.get(URI(string: "/api/auth/providers"))
            let afterBody = try JSONSerialization.jsonObject(with: Data(bodyText(providersAfter).utf8)) as? [String: Any]
            let afterProviders = afterBody?["providers"] as? [[String: Any]] ?? []
            #expect(afterProviders.first { $0["id"] as? String == "apple" }?["enabled"] as? Bool == true)

            let startAfter = try await client.get(URI(string: "/api/auth/apple/start?returnTo=/settings"))
            #expect(startAfter.status == .found)
            let location = startAfter.headers[.location] ?? ""
            let authorization = URLComponents(string: location)
            #expect(authorization?.scheme == "https")
            #expect(authorization?.host == "appleid.apple.com")
            #expect(authorization?.path == "/auth/authorize")
            #expect(authorization?.queryItems?.first { $0.name == "client_id" }?.value == "apple-client-id")
            #expect(authorization?.queryItems?.first { $0.name == "response_mode" }?.value == "form_post")
            #expect((authorization?.queryItems?.first { $0.name == "nonce" }?.value ?? "").isEmpty == false)
            let state = authorization?.queryItems?.first { $0.name == "state" }?.value ?? ""
            #expect(state.isEmpty == false)
            let setCookie = startAfter.headers[HTTPField.Name("Set-Cookie")!] ?? ""
            #expect(setCookie.contains("SameSite=None"))
            #expect(setCookie.contains("Secure"))

            let linkAfter = try await postJSON(
                client,
                "/api/auth/apple/link/start",
                body: "{\"returnTo\":\"/settings\"}",
                authorization: "Bearer \(token)"
            )
            #expect(linkAfter.status == .ok)
            let linkBody = try JSONSerialization.jsonObject(with: Data(bodyText(linkAfter).utf8)) as? [String: Any]
            let linkURL = linkBody?["url"] as? String ?? ""
            #expect(URLComponents(string: linkURL)?.queryItems?.first { $0.name == "response_mode" }?.value == "form_post")

            let mobileStart = try await postJSON(
                client,
                "/api/auth/mobile/oauth/start",
                body: "{\"provider\":\"apple\",\"mode\":\"login\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"abcdefghijklmnopqrstuvwxyzABCDEFGH\"}"
            )
            #expect(mobileStart.status == .notFound)

            let cookie = setCookie.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            var headers = HTTPFields()
            headers[.contentType] = "application/x-www-form-urlencoded"
            headers[.cookie] = cookie
            let encodedState = state.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_."))) ?? state
            let callback = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/apple/callback")) { request in
                request.body = .init(string: "state=\(encodedState)&error=user_cancelled_authorize")
            }
            #expect(callback.status == .found)
            let callbackItems = URLComponents(string: callback.headers[.location] ?? "")?.queryItems ?? []
            #expect(callbackItems.first { $0.name == "provider" }?.value == "apple")
            #expect(callbackItems.first { $0.name == "mode" }?.value == "login")
            #expect(callbackItems.first { $0.name == "error" }?.value == "user_cancelled_authorize")
        }
    }
}

@Test func appleFormPostLinkCallbackDoesNotChangeTheAccountUntilTheOwnerCompletes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "88888888-8888-4888-8888-888888888888"
    let otherId = "99999999-9999-4999-8999-999999999999"
    accounts.configuredSocialAuthProviders = ["apple"]
    accounts.appleClientId = "apple-client-id"
    accounts.allowAppleLogin(on: ["web"])
    accounts.webProviderProfile = MobileProviderProfile(
        providerUserId: "apple-route-link-sub",
        email: "apple-route-link-social@slock.test",
        displayName: nil
    )
    accounts.addAccount(id: ownerId, email: "apple-link-owner-binding@slock.test", password: "password123")
    accounts.addAccount(id: otherId, email: "apple-link-other-binding@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"apple-link-owner-binding@slock.test\",\"password\":\"password123\"}")
            let otherLogin = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"apple-link-other-binding@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let otherToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(otherLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""

            let start = try await postJSON(
                client,
                "/api/auth/apple/link/start",
                body: "{\"returnTo\":\"/settings?tab=account\"}",
                authorization: "Bearer \(ownerToken)"
            )
            #expect(start.status == .ok)
            let startBody = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let authorization = URLComponents(string: startBody?["url"] as? String ?? "")
            let state = authorization?.queryItems?.first { $0.name == "state" }?.value ?? ""
            let nonce = authorization?.queryItems?.first { $0.name == "nonce" }?.value ?? ""
            #expect(state.isEmpty == false)
            #expect(nonce.isEmpty == false)

            let encodedState = state.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_."))) ?? state
            var headers = HTTPFields()
            headers[.contentType] = "application/x-www-form-urlencoded"
            let callback = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/apple/callback")) { request in
                request.body = .init(string: "code=apple-route-link-code&state=\(encodedState)")
            }
            #expect(callback.status == .found)
            let callbackItems = URLComponents(string: callback.headers[.location] ?? "")?.queryItems ?? []
            #expect(callbackItems.first { $0.name == "mode" }?.value == "link")
            let completionCode = callbackItems.first { $0.name == "code" }?.value ?? ""
            #expect(completionCode.isEmpty == false)
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "apple").isEmpty)
            #expect(accounts.linkedProviderUserIds(userId: otherId, provider: "apple").isEmpty)

            let unauthenticated = try await postJSON(client, "/api/auth/apple/complete", body: "{\"code\":\"\(completionCode)\"}")
            #expect(unauthenticated.status == .unauthorized)
            let unauthenticatedBody = try JSONSerialization.jsonObject(with: Data(bodyText(unauthenticated).utf8)) as? [String: Any]
            #expect(unauthenticatedBody?["code"] as? String == "auth_required")
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "apple").isEmpty)

            let wrongUser = try await postJSON(
                client,
                "/api/auth/apple/complete",
                body: "{\"code\":\"\(completionCode)\"}",
                authorization: "Bearer \(otherToken)"
            )
            #expect(wrongUser.status == .forbidden)
            let wrongBody = try JSONSerialization.jsonObject(with: Data(bodyText(wrongUser).utf8)) as? [String: Any]
            #expect(wrongBody?["code"] as? String == "link_user_mismatch")
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "apple").isEmpty)
            #expect(accounts.linkedProviderUserIds(userId: otherId, provider: "apple").isEmpty)

            let ownerComplete = try await postJSON(
                client,
                "/api/auth/apple/complete",
                body: "{\"code\":\"\(completionCode)\"}",
                authorization: "Bearer \(ownerToken)"
            )
            #expect(ownerComplete.status == .ok)
            let ownerBody = try JSONSerialization.jsonObject(with: Data(bodyText(ownerComplete).utf8)) as? [String: Any]
            #expect(ownerBody?["mode"] as? String == "link")
            #expect(ownerBody?["accessToken"] == nil)
            #expect(ownerBody?["refreshToken"] == nil)
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "apple") == ["apple-route-link-sub"])
            #expect(accounts.linkedProviderUserIds(userId: otherId, provider: "apple").isEmpty)

            let replay = try await postJSON(
                client,
                "/api/auth/apple/complete",
                body: "{\"code\":\"\(completionCode)\"}",
                authorization: "Bearer \(ownerToken)"
            )
            #expect(replay.status == .badRequest)
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "apple") == ["apple-route-link-sub"])
        }
    }
}

@Test func unverifiedAppleEmailCannotPersistThroughWebOrMobileLink() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    accounts.configuredSocialAuthProviders = ["apple"]
    accounts.appleClientId = "apple-client-id"
    accounts.allowAppleLogin(on: ["web", "mobile"])
    accounts.mobileOAuthReturnURI = "raft-debug://oauth/callback"
    accounts.addAccount(id: ownerId, email: "apple-unverified-owner@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"apple-unverified-owner@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""

            let webStart = try await postJSON(
                client,
                "/api/auth/apple/link/start",
                body: "{\"returnTo\":\"/settings\"}",
                authorization: "Bearer \(token)"
            )
            #expect(webStart.status == .ok)
            let webURL = ((try JSONSerialization.jsonObject(with: Data(bodyText(webStart).utf8)) as? [String: Any])?["url"] as? String) ?? ""
            let webState = URLComponents(string: webURL)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            accounts.webProviderProfile = MobileProviderProfile(
                providerUserId: "apple-web-unverified-sub",
                email: "apple-unverified-owner@slock.test",
                displayName: nil,
                emailVerified: false
            )
            let encodedWebState = webState.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_."))) ?? webState
            var webHeaders = HTTPFields()
            webHeaders[.contentType] = "application/x-www-form-urlencoded"
            let webCallback = try await client.send(.post, headers: webHeaders, to: URI(string: "/api/auth/apple/callback")) { request in
                request.body = .init(string: "code=apple-web-unverified&state=\(encodedWebState)")
            }
            #expect(webCallback.status == .found)
            let webItems = URLComponents(string: webCallback.headers[.location] ?? "")?.queryItems ?? []
            let webError = webItems.first { $0.name == "error" }?.value ?? ""
            #expect(webError.contains("not verified") == true)
            #expect(webItems.contains { $0.name == "code" } == false)

            let mobileStart = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/link/start",
                body: "{\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"G8lRjTe2KR1WsgHPCbiqcJ78_4lpsWnZXwyArjWcJvs\"}",
                authorization: "Bearer \(token)"
            )
            #expect(mobileStart.status == .created)
            let mobileBody = try JSONSerialization.jsonObject(with: Data(bodyText(mobileStart).utf8)) as? [String: Any]
            let requestId = mobileBody?["requestId"] as? String ?? ""
            let mobileState = URLComponents(string: mobileBody?["authorizationUrl"] as? String ?? "")?.queryItems?.first { $0.name == "state" }?.value ?? ""
            accounts.mobileProviderProfile = MobileProviderProfile(
                providerUserId: "apple-mobile-unverified-sub",
                email: "apple-unverified-owner@slock.test",
                displayName: nil,
                emailVerified: false
            )
            let encodedMobileState = mobileState.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_."))) ?? mobileState
            var mobileHeaders = HTTPFields()
            mobileHeaders[.contentType] = "application/x-www-form-urlencoded"
            let mobileCallback = try await client.send(.post, headers: mobileHeaders, to: URI(string: "/api/auth/apple/callback")) { request in
                request.body = .init(string: "code=apple-mobile-unverified&state=\(encodedMobileState)")
            }
            #expect(mobileCallback.status == .found)
            let mobileItems = URLComponents(string: mobileCallback.headers[.location] ?? "")?.queryItems ?? []
            #expect(mobileItems.first { $0.name == "error" }?.value == "provider_exchange_failed")
            #expect(mobileItems.contains { $0.name == "code" } == false)
            #expect(accounts.oauthRequestStatus(id: requestId) == "failed")
            #expect(accounts.oauthRequestProviderUserId(id: requestId) == nil)
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "apple").isEmpty)
            #expect(accounts.isEmailVerified(userId: ownerId) == false)
        }
    }
}

private func base64urlJSON(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func jwtNumericClaim(_ token: String, name: String) -> Double? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3 else { return nil }
    var body = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = body.count % 4
    if remainder != 0 {
        body += String(repeating: "=", count: 4 - remainder)
    }
    guard let data = Data(base64Encoded: body),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let number = object[name] as? NSNumber { return number.doubleValue }
    return nil
}

private func appleIdentityToken(subject: String, nonce: String, email: String? = nil, emailVerified: Any = true, audience: String = "build.raft.app") -> String {
    let header = base64urlJSON(["alg": "RS256", "typ": "JWT"])
    var claims: [String: Any] = [
        "sub": subject,
        "nonce": nonce,
        "iss": "https://appleid.apple.com",
        "aud": audience,
        "exp": Int(Date().timeIntervalSince1970) + 300,
    ]
    if let email {
        claims["email"] = email
        claims["email_verified"] = emailVerified
    }
    return "\(header).\(base64urlJSON(claims)).sig"
}

private final class NativeAppleExchanges: @unchecked Sendable {
    var calls: [NativeAppleCodeExchange] = []
    var tokens: [String: String] = [:]
}

private final class ExchangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

@Test func nativeAppleIOSLoginVerifiesBothCredentialsAndPreservesTheLegalHandoff() async throws {
    let accounts = EmailLoginDirectory()
    let secret = "native-apple-request-capability-secret"
    accounts.nativeAppleClientId = "build.raft.app"
    accounts.nativeAppleClientSecret = "native-apple-client-secret"
    accounts.nativeAppleStateSecret = secret
    let exchanges = NativeAppleExchanges()
    accounts.exchangeNativeAppleCode = { request async in
        exchanges.calls.append(request)
        return exchanges.tokens[request.code]
    }
    let loginChallenge = "CbJjXWCZjxcTYirPVH_43kssx7RobpovoAuVwmxXZkY"
    let verifier = "native-apple-login-verifier-0123456789abcdef"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let beforeGate = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/start",
                body: "{\"mode\":\"login\",\"platform\":\"ios\",\"appEnv\":\"staging\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"ljHNqfxb9y3svSXVitABIakUtypsfiOdhDu35Ew06VI\",\"codeChallengeMethod\":\"S256\"}"
            )
            #expect(beforeGate.status == .notFound)

            accounts.allowAppleLogin(on: ["mobile"])
            accounts.nativeAppleClientSecret = ""
            let withoutSecret = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/start",
                body: "{\"mode\":\"login\",\"platform\":\"ios\",\"appEnv\":\"staging\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"39wFi_w1POJ-yoUwivzuWYEPnRzTyCsE2zHvK2PMxkw\",\"codeChallengeMethod\":\"S256\"}"
            )
            #expect(withoutSecret.status == .notFound)

            accounts.nativeAppleClientSecret = "native-apple-client-secret"
            let wrongPlatform = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/start",
                body: "{\"mode\":\"login\",\"platform\":\"android\",\"appEnv\":\"staging\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"Ejq39oq24K-hs7gPmFXN6Lo9HqRJOCZd2FyqE0gGYTI\",\"codeChallengeMethod\":\"S256\"}"
            )
            #expect(wrongPlatform.status == .badRequest)
            let wrongPlatformBody = try JSONSerialization.jsonObject(with: Data(bodyText(wrongPlatform).utf8)) as? [String: Any]
            #expect(wrongPlatformBody?["code"] as? String == "invalid_request")

            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/start",
                body: "{\"mode\":\"login\",\"platform\":\"ios\",\"appEnv\":\"staging\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"\(loginChallenge)\",\"codeChallengeMethod\":\"S256\"}"
            )
            #expect(start.status == .created)
            let startBody = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = startBody?["requestId"] as? String ?? ""
            let requestToken = startBody?["requestToken"] as? String ?? ""
            #expect(requestId.isEmpty == false)
            #expect(requestToken.isEmpty == false)
            #expect(startBody?["returnUri"] as? String == "raft-debug://oauth/callback")
            #expect(startBody?["authorizationUrl"] == nil)
            let expires = ISO8601DateFormatter().date(from: startBody?["expiresAt"] as? String ?? "")
            #expect((expires ?? .distantPast) > Date())
            #expect(accounts.oauthRequestStatus(id: requestId) == "pending_provider")
            #expect(accounts.oauthRequestCodeChallenge(id: requestId) == loginChallenge)

            let expiredToken = AuthTokenCodec.signNativeAppleRequestToken(
                secret: secret,
                requestId: requestId,
                mode: "login",
                codeChallenge: loginChallenge,
                expiresAt: Date(timeIntervalSinceNow: -60)
            )
            let expired = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/authorize",
                body: "{\"requestId\":\"\(requestId)\",\"requestToken\":\"\(expiredToken)\",\"authorizationCode\":\"must-not-be-exchanged\",\"identityToken\":\"must-not-be-verified\"}"
            )
            #expect(expired.status == .gone)
            let expiredBody = try JSONSerialization.jsonObject(with: Data(bodyText(expired).utf8)) as? [String: Any]
            #expect(expiredBody?["code"] as? String == "native_apple_request_expired")

            let wrongAlgorithm = base64urlJSON(["alg": "HS512", "typ": "JWT"]) + "." + base64urlJSON(["kind": "native_apple_ios"]) + ".sig"
            let wrongAlgorithmReply = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/authorize",
                body: "{\"requestId\":\"\(requestId)\",\"requestToken\":\"\(wrongAlgorithm)\",\"authorizationCode\":\"must-not-be-exchanged\",\"identityToken\":\"must-not-be-verified\"}"
            )
            #expect(wrongAlgorithmReply.status == .badRequest)
            let wrongAlgorithmBody = try JSONSerialization.jsonObject(with: Data(bodyText(wrongAlgorithmReply).utf8)) as? [String: Any]
            #expect(wrongAlgorithmBody?["code"] as? String == "native_apple_invalid_credential")
            #expect(exchanges.calls.isEmpty)
            #expect(accounts.oauthRequestStatus(id: requestId) == "pending_provider")

            let unrelated = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/start",
                body: "{\"mode\":\"login\",\"platform\":\"ios\",\"appEnv\":\"staging\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"02_YRPDhWJB8E678Ukn5isb2NXQIyRHYgq5lt0H7x2M\",\"codeChallengeMethod\":\"S256\"}"
            )
            #expect(unrelated.status == .created)
            let unrelatedToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(unrelated).utf8)) as? [String: Any])?["requestToken"] as? String) ?? ""
            let crossBound = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/authorize",
                body: "{\"requestId\":\"\(requestId)\",\"requestToken\":\"\(unrelatedToken)\",\"authorizationCode\":\"must-not-be-exchanged\",\"identityToken\":\"must-not-be-verified\"}"
            )
            #expect(crossBound.status == .badRequest)
            let crossBody = try JSONSerialization.jsonObject(with: Data(bodyText(crossBound).utf8)) as? [String: Any]
            #expect(crossBody?["code"] as? String == "native_apple_invalid_credential")
            #expect(accounts.oauthRequestStatus(id: requestId) == "pending_provider")
            #expect(exchanges.calls.isEmpty)

            let supplied = appleIdentityToken(
                subject: "native-apple-login-subject",
                nonce: loginChallenge,
                email: "native-apple-login@slock.test",
                emailVerified: true
            )
            exchanges.tokens["native-apple-login-code"] = appleIdentityToken(
                subject: "native-apple-login-subject",
                nonce: loginChallenge,
                email: "native-apple-login@slock.test",
                emailVerified: "true"
            )
            let authorize = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/authorize",
                body: "{\"requestId\":\"\(requestId)\",\"requestToken\":\"\(requestToken)\",\"authorizationCode\":\"native-apple-login-code\",\"identityToken\":\"\(supplied)\"}"
            )
            #expect(authorize.status == .ok)
            let authorizeBody = try JSONSerialization.jsonObject(with: Data(bodyText(authorize).utf8)) as? [String: Any]
            let handoff = authorizeBody?["handoffCode"] as? String ?? ""
            #expect(authorizeBody?["requestId"] as? String == requestId)
            #expect(handoff.isEmpty == false)
            #expect(authorizeBody?["provider"] as? String == "apple")
            #expect(authorizeBody?["mode"] as? String == "login")
            #expect(exchanges.calls.count == 1)
            #expect(exchanges.calls[0].clientId == "build.raft.app")
            #expect(exchanges.calls[0].clientSecret == "native-apple-client-secret")
            #expect(exchanges.calls[0].grantType == "authorization_code")
            #expect(exchanges.calls[0].redirectUri == nil)
            #expect(accounts.oauthRequestStatus(id: requestId) == "provider_completed")
            #expect(accounts.oauthRequestProviderUserId(id: requestId) == "native-apple-login-subject")
            #expect(accounts.oauthRequestProviderEmail(id: requestId) == "native-apple-login@slock.test")

            let authorizeReplay = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/authorize",
                body: "{\"requestId\":\"\(requestId)\",\"requestToken\":\"\(requestToken)\",\"authorizationCode\":\"native-apple-login-code\",\"identityToken\":\"\(supplied)\"}"
            )
            #expect(authorizeReplay.status == .gone)
            let replayBody = try JSONSerialization.jsonObject(with: Data(bodyText(authorizeReplay).utf8)) as? [String: Any]
            #expect(replayBody?["code"] as? String == "native_apple_request_consumed")
            #expect(exchanges.calls.count == 1)

            let missingLegal = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\",\"platform\":\"ios\"}"
            )
            #expect(missingLegal.status == .unprocessableContent)
            let missingBody = try JSONSerialization.jsonObject(with: Data(bodyText(missingLegal).utf8)) as? [String: Any]
            #expect(missingBody?["error"] as? String == "LEGAL_ACCEPTANCE_REQUIRED")
            #expect(accounts.oauthRequestStatus(id: requestId) == "provider_completed")

            let accepted = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\",\"platform\":\"ios\",\"acceptTerms\":true,\"termsVersion\":\"2026-05-12\",\"privacyVersion\":\"2026-05-12\"}"
            )
            #expect(accepted.status == .ok)
            let acceptedBody = try JSONSerialization.jsonObject(with: Data(bodyText(accepted).utf8)) as? [String: Any]
            let user = acceptedBody?["user"] as? [String: Any]
            let userId = user?["id"] as? String ?? ""
            #expect(user?["email"] as? String == "native-apple-login@slock.test")
            #expect((acceptedBody?["accessToken"] as? String)?.isEmpty == false)
            #expect((acceptedBody?["refreshToken"] as? String)?.isEmpty == false)
            #expect(accounts.linkedProviderUserIds(userId: userId, provider: "apple") == ["native-apple-login-subject"])

            let handoffReplay = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"\(verifier)\",\"platform\":\"ios\"}"
            )
            #expect(handoffReplay.status == .gone)
            let handoffReplayBody = try JSONSerialization.jsonObject(with: Data(bodyText(handoffReplay).utf8)) as? [String: Any]
            #expect(handoffReplayBody?["code"] as? String == "handoff_code_consumed")
        }
    }
}

private final class NativeAppleAuthorizeBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var consumed: ClientResponse?
    private var consumedWaiters: [CheckedContinuation<ClientResponse, Never>] = []
    private var exchanges = 0

    var exchangeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return exchanges
    }

    func enterExchange() async {
        markStarted().forEach { $0.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.enqueueRelease(continuation)
        }
    }

    func waitUntilStarted() async {
        if alreadyStarted() { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.enqueueStarted(continuation)
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiters = releaseWaiters
        releaseWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func recordConsumed(_ response: ClientResponse) {
        lock.lock()
        consumed = response
        let waiters = consumedWaiters
        consumedWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume(returning: response) }
    }

    func waitConsumed() async -> ClientResponse {
        if let existing = takeConsumed() { return existing }
        return await withCheckedContinuation { (continuation: CheckedContinuation<ClientResponse, Never>) in
            self.enqueueConsumed(continuation)
        }
    }

    private func markStarted() -> [CheckedContinuation<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        exchanges += 1
        started = true
        let waiters = startedWaiters
        startedWaiters = []
        return waiters
    }

    private func enqueueRelease(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if released {
            continuation.resume()
        } else {
            releaseWaiters.append(continuation)
        }
    }

    private func alreadyStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    private func enqueueStarted(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if started {
            continuation.resume()
        } else {
            startedWaiters.append(continuation)
        }
    }

    private func takeConsumed() -> ClientResponse? {
        lock.lock()
        defer { lock.unlock() }
        return consumed
    }

    private func enqueueConsumed(_ continuation: CheckedContinuation<ClientResponse, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if let consumed {
            continuation.resume(returning: consumed)
        } else {
            consumedWaiters.append(continuation)
        }
    }
}

@Test func nativeAppleAuthorizeClaimsTheRowBeforeTheCodeExchange() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeAppleClientId = "build.raft.app"
    accounts.nativeAppleClientSecret = "native-apple-client-secret"
    accounts.nativeAppleStateSecret = "native-apple-request-capability-secret"
    accounts.allowAppleLogin(on: ["mobile"])
    let barrier = NativeAppleAuthorizeBarrier()
    let challenge = "rp1L600Z3zab7r8wRCcv3BMaph53yjpVOpX3oK0PafQ"
    let subject = "native-apple-concurrent-subject"
    let email = "native-apple-concurrent@slock.test"
    accounts.exchangeNativeAppleCode = { _ in
        await barrier.enterExchange()
        return appleIdentityToken(subject: subject, nonce: challenge, email: email, emailVerified: true)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/start",
                body: "{\"mode\":\"login\",\"platform\":\"ios\",\"appEnv\":\"staging\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"\(challenge)\",\"codeChallengeMethod\":\"S256\"}"
            )
            #expect(start.status == .created)
            let started = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = started?["requestId"] as? String ?? ""
            let requestToken = started?["requestToken"] as? String ?? ""
            let supplied = appleIdentityToken(subject: subject, nonce: challenge, email: email, emailVerified: true)
            let authorizeBody = "{\"requestId\":\"\(requestId)\",\"requestToken\":\"\(requestToken)\",\"authorizationCode\":\"native-apple-concurrent-code\",\"identityToken\":\"\(supplied)\"}"

            func attempt() async throws -> ClientResponse {
                let response = try await postJSON(client, "/api/auth/mobile/oauth/apple/native/authorize", body: authorizeBody)
                if response.status == .gone {
                    barrier.recordConsumed(response)
                }
                return response
            }

            async let first = attempt()
            async let second = attempt()
            await barrier.waitUntilStarted()
            let rejected = await barrier.waitConsumed()
            #expect(rejected.status == .gone)
            let rejectedBody = try JSONSerialization.jsonObject(with: Data(bodyText(rejected).utf8)) as? [String: Any]
            #expect(rejectedBody?["code"] as? String == "native_apple_request_consumed")
            #expect(barrier.exchangeCount == 1)
            barrier.release()

            let responses = try await [first, second]
            #expect(responses.contains { $0.status == .ok })
            #expect(responses.contains { $0.status == .gone })
            let succeeded = responses.first { $0.status == .ok }
            let successBody = try JSONSerialization.jsonObject(with: Data(bodyText(succeeded ?? rejected).utf8)) as? [String: Any]
            let handoff = successBody?["handoffCode"] as? String ?? ""
            #expect(successBody?["requestId"] as? String == requestId)
            #expect(handoff.isEmpty == false)
            #expect(barrier.exchangeCount == 1)
            #expect(accounts.oauthRequestStatus(id: requestId) == "provider_completed")
            #expect(accounts.oauthRequestCodeHash(id: requestId) == AuthTokenCodec.sha256Hex(handoff))
            #expect(accounts.oauthRequestProviderUserId(id: requestId) == subject)
        }
    }
}

@Test func nativeAppleAuthorizeExpiresFromTheRowWhileTheRequestTokenIsStillValid() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeAppleClientId = "build.raft.app"
    accounts.nativeAppleClientSecret = "native-apple-client-secret"
    accounts.nativeAppleStateSecret = "native-apple-request-capability-secret"
    accounts.allowAppleLogin(on: ["mobile"])
    let exchanges = ExchangeCounter()
    accounts.exchangeNativeAppleCode = { _ in
        exchanges.record()
        return "must-not-be-verified"
    }
    let challenge = "gRdfxIrs8i_xC4ieRa105lwST9s0QctbbsE05_peuEM"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let start = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/start",
                body: "{\"mode\":\"login\",\"platform\":\"ios\",\"appEnv\":\"staging\",\"returnUri\":\"raft-debug://oauth/callback\",\"codeChallenge\":\"\(challenge)\",\"codeChallengeMethod\":\"S256\"}"
            )
            #expect(start.status == .created)
            let started = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
            let requestId = started?["requestId"] as? String ?? ""
            let requestToken = started?["requestToken"] as? String ?? ""
            let exp = jwtNumericClaim(requestToken, name: "exp") ?? 0
            #expect(exp * 1_000 > Date().timeIntervalSince1970 * 1_000)

            accounts.expireMobileOAuthRequest(id: requestId)
            let expiredAt = accounts.oauthRequestExpiresAt(id: requestId)
            #expect(accounts.oauthRequestStatus(id: requestId) == "pending_provider")
            #expect(accounts.oauthRequestCodeHash(id: requestId) == nil)
            #expect(expiredAt != nil)
            #expect((expiredAt ?? .distantFuture) < Date())

            let authorize = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/authorize",
                body: "{\"requestId\":\"\(requestId)\",\"requestToken\":\"\(requestToken)\",\"authorizationCode\":\"must-not-be-exchanged\",\"identityToken\":\"must-not-be-verified\"}"
            )
            #expect(authorize.status == .gone)
            let authorizeBody = try JSONSerialization.jsonObject(with: Data(bodyText(authorize).utf8)) as? [String: Any]
            #expect(authorizeBody?["code"] as? String == "native_apple_request_expired")
            #expect(authorizeBody?["error"] as? String == "Apple sign-in request expired")
            #expect(exchanges.value == 0)
            #expect(accounts.oauthRequestStatus(id: requestId) == "expired")
            #expect(accounts.oauthRequestStatus(id: requestId) != "provider_processing")
            #expect(accounts.oauthRequestCodeHash(id: requestId) == nil)
            #expect(accounts.oauthRequestExpiresAt(id: requestId) == expiredAt)
            #expect((accounts.oauthRequestExpiresAt(id: requestId) ?? .distantFuture) < Date())
        }
    }
}

@Test func nativeAppleLinkIsOwnerBoundAndLaterLoginReusesTheVerifiedStoredEmail() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeAppleClientId = "build.raft.app"
    accounts.nativeAppleClientSecret = "native-apple-client-secret"
    accounts.nativeAppleStateSecret = "native-apple-request-capability-secret"
    accounts.allowAppleLogin(on: ["mobile"])
    let ownerId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
    let otherId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"
    let ownerEmail = "native-apple-link-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.addAccount(id: otherId, email: "native-apple-link-other@slock.test", password: "password123")
    let exchanges = NativeAppleExchanges()
    accounts.exchangeNativeAppleCode = { request in
        exchanges.calls.append(request)
        return exchanges.tokens[request.code]
    }
    let subject = "native-apple-linked-subject"
    let ownerChallenge = "J5nSViUq2sYrA9SexY8TxhLDREfA0vgW3cyst8anku8"
    let laterChallenge = "_oFr4fp0yg5ADmKHtzHzNIEEWLWUlmB1yAlENXEVZLk"
    let missingChallenge = "jEyBNT3PvU30VAJPd-WwnLB2WoE6IF_U_Jt7soGXNH0"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func token(email: String) async throws -> String {
                let login = try await postJSON(
                    client,
                    "/api/auth/login",
                    body: "{\"email\":\"\(email)\",\"password\":\"password123\"}"
                )
                #expect(login.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any]
                return body?["accessToken"] as? String ?? ""
            }
            let ownerToken = try await token(email: ownerEmail)
            let otherToken = try await token(email: "native-apple-link-other@slock.test")

            let unauthenticated = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/start",
                body: "{\"mode\":\"link\",\"platform\":\"ios\",\"appEnv\":\"production\",\"returnUri\":\"raft://oauth/callback\",\"codeChallenge\":\"mKuCmD1xdw8OFqTgQwJzPP5CRGiP8sqJ2a_jHiF2Ia0\",\"codeChallengeMethod\":\"S256\"}"
            )
            #expect(unauthenticated.status == .unauthorized)
            let unauthenticatedBody = try JSONSerialization.jsonObject(with: Data(bodyText(unauthenticated).utf8)) as? [String: Any]
            #expect(unauthenticatedBody?["code"] as? String == "auth_required")
            #expect(unauthenticatedBody?["error"] as? String == "Apple account linking requires authentication")
            #expect(accounts.mobileOAuthRequestCount == 0)

            let linkStart = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/start",
                body: "{\"mode\":\"link\",\"platform\":\"ios\",\"appEnv\":\"production\",\"returnUri\":\"raft://oauth/callback\",\"codeChallenge\":\"\(ownerChallenge)\",\"codeChallengeMethod\":\"S256\"}",
                authorization: "Bearer \(ownerToken)"
            )
            #expect(linkStart.status == .created)
            let started = try JSONSerialization.jsonObject(with: Data(bodyText(linkStart).utf8)) as? [String: Any]
            let requestId = started?["requestId"] as? String ?? ""
            let requestToken = started?["requestToken"] as? String ?? ""
            let supplied = appleIdentityToken(subject: subject, nonce: ownerChallenge, email: ownerEmail, emailVerified: true)
            exchanges.tokens["native-apple-link-code"] = appleIdentityToken(subject: subject, nonce: ownerChallenge, email: ownerEmail, emailVerified: true)
            let authorizeBody = "{\"requestId\":\"\(requestId)\",\"requestToken\":\"\(requestToken)\",\"authorizationCode\":\"native-apple-link-code\",\"identityToken\":\"\(supplied)\"}"

            let noAuth = try await postJSON(client, "/api/auth/mobile/oauth/apple/native/authorize", body: authorizeBody)
            #expect(noAuth.status == .unauthorized)
            let noAuthBody = try JSONSerialization.jsonObject(with: Data(bodyText(noAuth).utf8)) as? [String: Any]
            #expect(noAuthBody?["code"] as? String == "auth_required")
            let wrongOwner = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/authorize",
                body: authorizeBody,
                authorization: "Bearer \(otherToken)"
            )
            #expect(wrongOwner.status == .forbidden)
            let wrongOwnerBody = try JSONSerialization.jsonObject(with: Data(bodyText(wrongOwner).utf8)) as? [String: Any]
            #expect(wrongOwnerBody?["code"] as? String == "link_user_mismatch")
            #expect(wrongOwnerBody?["error"] as? String == "Apple account linking does not match the authenticated user")
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "apple").isEmpty)
            #expect(accounts.oauthRequestStatus(id: requestId) == "pending_provider")
            #expect(exchanges.calls.isEmpty)

            let ownerAuthorize = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/authorize",
                body: authorizeBody,
                authorization: "Bearer \(ownerToken)"
            )
            #expect(ownerAuthorize.status == .ok)
            let ownerAuthorizeBody = try JSONSerialization.jsonObject(with: Data(bodyText(ownerAuthorize).utf8)) as? [String: Any]
            let handoff = ownerAuthorizeBody?["handoffCode"] as? String ?? ""
            #expect(handoff.isEmpty == false)
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "apple").isEmpty)
            #expect(exchanges.calls.count == 1)

            let wrongFinal = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/link/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"native-apple-link-owner-verifier-0123456789\"}",
                authorization: "Bearer \(otherToken)"
            )
            #expect(wrongFinal.status == .forbidden)
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "apple").isEmpty)
            #expect(accounts.oauthRequestStatus(id: requestId) == "provider_completed")

            let ownerComplete = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/link/complete",
                body: "{\"code\":\"\(handoff)\",\"codeVerifier\":\"native-apple-link-owner-verifier-0123456789\"}",
                authorization: "Bearer \(ownerToken)"
            )
            #expect(ownerComplete.status == .ok)
            #expect(accounts.linkedProviderUserIds(userId: ownerId, provider: "apple") == [subject])
            #expect(accounts.linkedProviderEmail(userId: ownerId, provider: "apple") == ownerEmail)

            let laterStart = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/start",
                body: "{\"mode\":\"login\",\"platform\":\"ios\",\"appEnv\":\"production\",\"returnUri\":\"raft://oauth/callback\",\"codeChallenge\":\"\(laterChallenge)\",\"codeChallengeMethod\":\"S256\"}"
            )
            #expect(laterStart.status == .created)
            let laterStarted = try JSONSerialization.jsonObject(with: Data(bodyText(laterStart).utf8)) as? [String: Any]
            let laterId = laterStarted?["requestId"] as? String ?? ""
            let laterToken = laterStarted?["requestToken"] as? String ?? ""
            let laterSupplied = appleIdentityToken(subject: subject, nonce: laterChallenge)
            exchanges.tokens["native-apple-later-code"] = appleIdentityToken(subject: subject, nonce: laterChallenge)
            let laterAuthorize = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/authorize",
                body: "{\"requestId\":\"\(laterId)\",\"requestToken\":\"\(laterToken)\",\"authorizationCode\":\"native-apple-later-code\",\"identityToken\":\"\(laterSupplied)\"}"
            )
            #expect(laterAuthorize.status == .ok)
            let laterHandoff = ((try JSONSerialization.jsonObject(with: Data(bodyText(laterAuthorize).utf8)) as? [String: Any])?["handoffCode"] as? String) ?? ""
            let laterComplete = try await postJSON(
                client,
                "/api/auth/mobile/oauth/complete",
                body: "{\"code\":\"\(laterHandoff)\",\"codeVerifier\":\"native-apple-later-login-verifier-0123456789\",\"platform\":\"ios\"}"
            )
            #expect(laterComplete.status == .ok)
            let laterUser = (try JSONSerialization.jsonObject(with: Data(bodyText(laterComplete).utf8)) as? [String: Any])?["user"] as? [String: Any]
            #expect(laterUser?["id"] as? String == ownerId)
            #expect(accounts.userCount == 2)

            let firstStart = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/start",
                body: "{\"mode\":\"login\",\"platform\":\"ios\",\"appEnv\":\"production\",\"returnUri\":\"raft://oauth/callback\",\"codeChallenge\":\"\(missingChallenge)\",\"codeChallengeMethod\":\"S256\"}"
            )
            #expect(firstStart.status == .created)
            let firstStarted = try JSONSerialization.jsonObject(with: Data(bodyText(firstStart).utf8)) as? [String: Any]
            let firstId = firstStarted?["requestId"] as? String ?? ""
            let firstToken = firstStarted?["requestToken"] as? String ?? ""
            let firstSupplied = appleIdentityToken(subject: "native-apple-new-missing-email-subject", nonce: missingChallenge)
            exchanges.tokens["native-apple-first-missing-email-code"] = appleIdentityToken(
                subject: "native-apple-new-missing-email-subject",
                nonce: missingChallenge
            )
            let firstAuthorize = try await postJSON(
                client,
                "/api/auth/mobile/oauth/apple/native/authorize",
                body: "{\"requestId\":\"\(firstId)\",\"requestToken\":\"\(firstToken)\",\"authorizationCode\":\"native-apple-first-missing-email-code\",\"identityToken\":\"\(firstSupplied)\"}"
            )
            #expect(firstAuthorize.status == .badRequest)
            let firstBody = try JSONSerialization.jsonObject(with: Data(bodyText(firstAuthorize).utf8)) as? [String: Any]
            #expect(firstBody?["code"] as? String == "native_apple_invalid_credential")
            #expect(accounts.oauthRequestStatus(id: firstId) == "failed")
            #expect(accounts.userCount == 2)
        }
    }
}

@Test func nativeAppleAuthorizeFailsTerminallyWhenIdentityClaimsDisagree() async throws {
    let accounts = EmailLoginDirectory()
    accounts.nativeAppleClientId = "build.raft.app"
    accounts.nativeAppleClientSecret = "native-apple-client-secret"
    accounts.nativeAppleStateSecret = "native-apple-request-capability-secret"
    accounts.allowAppleLogin(on: ["mobile"])
    let exchanges = NativeAppleExchanges()
    accounts.exchangeNativeAppleCode = { request in
        exchanges.calls.append(request)
        return exchanges.tokens[request.code]
    }
    let cases: [(name: String, challenge: String, supplied: (String) -> String, exchanged: (String) -> String)] = [
        (
            "nonce",
            "native-apple-nonce-challenge-0123456789abcd",
            { challenge in
                appleIdentityToken(
                    subject: "native-apple-invalid-nonce",
                    nonce: String(challenge.dropLast()) + "x",
                    email: "native-apple-invalid-nonce@slock.test"
                )
            },
            { challenge in
                appleIdentityToken(
                    subject: "native-apple-invalid-nonce",
                    nonce: challenge,
                    email: "native-apple-invalid-nonce@slock.test"
                )
            }
        ),
        (
            "audience",
            "native-apple-audience-challenge-0123456789ab",
            { challenge in
                appleIdentityToken(
                    subject: "native-apple-invalid-audience",
                    nonce: challenge,
                    email: "native-apple-invalid-audience@slock.test",
                    audience: "wrong.native.app"
                )
            },
            { challenge in
                appleIdentityToken(
                    subject: "native-apple-invalid-audience",
                    nonce: challenge,
                    email: "native-apple-invalid-audience@slock.test"
                )
            }
        ),
        (
            "subject",
            "native-apple-subject-challenge-0123456789abcd",
            { challenge in
                appleIdentityToken(
                    subject: "native-apple-subject-a",
                    nonce: challenge,
                    email: "native-apple-invalid-subject@slock.test"
                )
            },
            { challenge in
                appleIdentityToken(
                    subject: "native-apple-subject-b",
                    nonce: challenge,
                    email: "native-apple-invalid-subject@slock.test"
                )
            }
        ),
        (
            "email",
            "native-apple-email-challenge-0123456789abcdef",
            { challenge in
                appleIdentityToken(
                    subject: "native-apple-invalid-email",
                    nonce: challenge,
                    email: "native-apple-email-a@slock.test"
                )
            },
            { challenge in
                appleIdentityToken(
                    subject: "native-apple-invalid-email",
                    nonce: challenge,
                    email: "native-apple-email-b@slock.test"
                )
            }
        ),
        (
            "email-verification",
            "native-apple-unverified-challenge-0123456789ab",
            { challenge in
                appleIdentityToken(
                    subject: "native-apple-unverified-email",
                    nonce: challenge,
                    email: "native-apple-unverified-email@slock.test",
                    emailVerified: false
                )
            },
            { challenge in
                appleIdentityToken(
                    subject: "native-apple-unverified-email",
                    nonce: challenge,
                    email: "native-apple-unverified-email@slock.test"
                )
            }
        ),
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            for invalid in cases {
                let start = try await postJSON(
                    client,
                    "/api/auth/mobile/oauth/apple/native/start",
                    body: "{\"mode\":\"login\",\"platform\":\"ios\",\"appEnv\":\"production\",\"returnUri\":\"raft://oauth/callback\",\"codeChallenge\":\"\(invalid.challenge)\",\"codeChallengeMethod\":\"S256\"}"
                )
                #expect(start.status == .created)
                let started = try JSONSerialization.jsonObject(with: Data(bodyText(start).utf8)) as? [String: Any]
                let requestId = started?["requestId"] as? String ?? ""
                let requestToken = started?["requestToken"] as? String ?? ""
                let authorizationCode = "native-apple-invalid-\(invalid.name)-code"
                exchanges.tokens[authorizationCode] = invalid.exchanged(invalid.challenge)
                let body = "{\"requestId\":\"\(requestId)\",\"requestToken\":\"\(requestToken)\",\"authorizationCode\":\"\(authorizationCode)\",\"identityToken\":\"\(invalid.supplied(invalid.challenge))\"}"
                let authorize = try await postJSON(client, "/api/auth/mobile/oauth/apple/native/authorize", body: body)
                #expect(authorize.status == .badRequest)
                let authorizeBody = try JSONSerialization.jsonObject(with: Data(bodyText(authorize).utf8)) as? [String: Any]
                #expect(authorizeBody?["code"] as? String == "native_apple_invalid_credential")
                #expect(accounts.oauthRequestStatus(id: requestId) == "failed")
                let replay = try await postJSON(client, "/api/auth/mobile/oauth/apple/native/authorize", body: body)
                #expect(replay.status == .gone)
                let replayBody = try JSONSerialization.jsonObject(with: Data(bodyText(replay).utf8)) as? [String: Any]
                #expect(replayBody?["code"] as? String == "native_apple_request_consumed")
            }
        }
    }
}
