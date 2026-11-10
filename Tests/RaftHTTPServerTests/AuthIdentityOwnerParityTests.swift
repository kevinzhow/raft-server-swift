import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

// Published-path parity for the two identity-owner gaps:
//
// - `PATCH /api/auth/me` description (pinned `routes/auth.ts:1486-1537,1618`;
//   the 3000-character cap and JS `.trim()` semantics).
// - One linked-identity table for `GET/DELETE /api/auth/identities`, the social
//   link completion and `toPublicUser.profileSetupProvider` (pinned
//   `db/schema.ts:159-171`; `services/userService.ts:187-198,658-735`;
//   `routes/auth.ts:732-768,1160-1188`).

private func ownerSend(
    _ client: any Client,
    _ method: HTTPRequest.Method,
    _ path: String,
    bearer: String? = nil,
    body: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    if body != nil { headers[.contentType] = "application/json" }
    if let bearer { headers[.authorization] = "Bearer \(bearer)" }
    return try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
}

private func ownerJSON(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func ownerDescription(_ response: ClientResponse) -> Any? {
    ownerJSON(response)["description"] ?? NSNull()
}

@Test func patchMeDescriptionValidatesTrimsClearsAndPersistsLikeUpstream() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000003100001"
    let email = "description-parity@slock.test"
    accounts.addAccount(id: userId, email: email, password: "password123")
    accounts.markEmailVerified(userId: userId)
    let bearer = accounts.mintAccessTokenForTesting(userId: userId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            func patch(_ body: String) async throws -> ClientResponse {
                try await ownerSend(client, .patch, "/api/auth/me", bearer: bearer, body: body)
            }
            func me() async throws -> ClientResponse {
                try await ownerSend(client, .get, "/api/auth/me", bearer: bearer)
            }
            let errorBody = #"{"error":"Description must be a string of at most 3000 characters"}"#

            let initial = try await me()
            #expect(initial.status == .ok)
            #expect(ownerDescription(initial) is NSNull)

            // Non-string values are refused, including the JSON forms the old
            // Foundation object parser could bridge.
            for body in [
                #"{"description":5}"#,
                #"{"description":1}"#,
                #"{"description":0}"#,
                #"{"description":true}"#,
                #"{"description":{}}"#,
                #"{"description":[]}"#,
            ] {
                let rejected = try await patch(body)
                #expect(rejected.status == .badRequest, Comment(rawValue: body))
                #expect(rejected.body.string == errorBody, Comment(rawValue: body))
            }

            // The length cap is checked on the raw string with JavaScript
            // UTF-16 code units, before trimming: 3001 spaces are still too long.
            let tooLong = String(repeating: "a", count: 3001)
            #expect((try await patch(#"{"description":"\#(tooLong)"}"#)).body.string == errorBody)
            #expect((try await patch(#"{"description":"\#(String(repeating: " ", count: 3001))"}"#)).body.string == errorBody)
            #expect((try await patch(#"{"description":"\#(String(repeating: "😀", count: 1501))"}"#)).body.string == errorBody)

            // Exactly 3000 UTF-16 units is accepted; 1500 emoji are 3000 units.
            let accepted = try await patch(#"{"description":"\#(tooLong.dropLast())"}"#)
            #expect(accepted.status == .ok)
            #expect(ownerDescription(accepted) as? String == String(tooLong.dropLast()))
            #expect((try await patch(#"{"description":"\#(String(repeating: "😀", count: 1500))"}"#)).status == .ok)

            // JS `trim()` then `|| null`: surrounding whitespace is removed and a
            // whitespace-only value clears the field.
            let trimmed = try await patch(#"{"description":"  hello \n\t "}"#)
            #expect(trimmed.status == .ok)
            #expect(ownerDescription(trimmed) as? String == "hello")
            let blank = try await patch(#"{"description":"   \n\t "}"#)
            #expect(blank.status == .ok)
            #expect(ownerDescription(blank) is NSNull)

            // Explicit null clears; an absent key leaves the stored value alone.
            #expect((try await patch(#"{"description":"kept"}"#)).status == .ok)
            #expect((try await patch(#"{"displayLanguage":"en"}"#)).status == .ok)
            #expect(ownerDescription(try await me()) as? String == "kept")
            let cleared = try await patch(#"{"description":null}"#)
            #expect(cleared.status == .ok)
            #expect(ownerDescription(cleared) is NSNull)

            // A rejected request writes no profile field. Description is validated
            // before the later preference keys, and before the survey/referral write.
            #expect((try await patch(#"{"description":"kept"}"#)).status == .ok)
            let laterField = try await patch(#"{"description":"changed","preferredTimezone":"Mars/Base"}"#)
            #expect(laterField.body.string == #"{"error":"Invalid preferredTimezone"}"#)
            #expect(ownerDescription(try await me()) as? String == "kept")
            #expect(ownerJSON(try await me())["preferredTimezone"] is NSNull)

            let laterDescription = try await patch(#"{"description":5,"preferredTimezone":"Asia/Tokyo"}"#)
            #expect(laterDescription.body.string == errorBody)
            #expect(ownerDescription(try await me()) as? String == "kept")
            #expect(ownerJSON(try await me())["preferredTimezone"] is NSNull)

            let survey = try await patch(#"{"description":"changed","signupRole":"intern"}"#)
            #expect(survey.body.string == #"{"error":"Invalid signupRole"}"#)
            #expect(ownerDescription(try await me()) as? String == "kept")
            #expect(ownerJSON(try await me())["signupRole"] is NSNull)
            #expect(ownerJSON(try await me())["signupSurveyCompletedAt"] is NSNull)

            // The existing password-change order is unchanged: a wrong current
            // password is answered before description validation, and a short new
            // password before that.
            let wrongPassword = try await ownerSend(
                client, .patch, "/api/auth/me", bearer: bearer,
                body: #"{"currentPassword":"wrong","newPassword":"longenough1","description":5}"#
            )
            #expect(wrongPassword.status == .unauthorized)
            #expect(wrongPassword.body.string == #"{"code":"AUTH_CURRENT_PASSWORD_INCORRECT","error":"Current password is incorrect"}"#)
            let shortPassword = try await ownerSend(
                client, .patch, "/api/auth/me", bearer: bearer,
                body: #"{"currentPassword":"password123","newPassword":"short","description":5}"#
            )
            #expect(shortPassword.body.string == #"{"error":"New password must be at least 8 characters"}"#)
            #expect(ownerDescription(try await me()) as? String == "kept")
        }
    }
}

@Test func socialLinkListUnlinkAndProfileProviderReadOneIdentityOwner() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-000003100002"
    let email = "identity-owner@slock.test"
    accounts.addAccount(id: userId, email: email, password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.addSocialCompletion(
        provider: "github", code: "link-github", email: email,
        mode: "link", intendedAction: "link", userId: userId, providerUserId: "github-subject-1"
    )
    accounts.addSocialCompletion(
        provider: "google", code: "link-google", email: email,
        mode: "link", intendedAction: "link", userId: userId, providerUserId: "google-subject-1"
    )
    let bearer = accounts.mintAccessTokenForTesting(userId: userId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            func link(_ provider: String, code: String) async throws -> ClientResponse {
                try await ownerSend(client, .post, "/api/auth/\(provider)/complete", bearer: bearer, body: #"{"code":"\#(code)"}"#)
            }
            func list() async throws -> ClientResponse {
                try await ownerSend(client, .get, "/api/auth/identities", bearer: bearer)
            }
            func me() async throws -> [String: Any] {
                ownerJSON(try await ownerSend(client, .get, "/api/auth/me", bearer: bearer))
            }
            func unlink(_ provider: String) async throws -> ClientResponse {
                try await ownerSend(client, .delete, "/api/auth/identities/\(provider)", bearer: bearer)
            }

            // The completion body is the same ordered identity list upstream
            // `listUserAuthIdentities` publishes (`{provider, providerEmail}`).
            let firstLink = try await link("github", code: "link-github")
            #expect(firstLink.status == .ok)
            let firstLinkBody = ownerJSON(firstLink)
            #expect(firstLinkBody["provider"] as? String == "github")
            #expect(firstLinkBody["mode"] as? String == "link")
            #expect(firstLinkBody["accessToken"] == nil)
            #expect(firstLinkBody["refreshToken"] == nil)
            let linkedIdentities = try #require(firstLinkBody["identities"] as? [[String: Any]])
            #expect(linkedIdentities.count == 1)
            #expect(linkedIdentities[0]["provider"] as? String == "github")
            #expect(linkedIdentities[0]["providerEmail"] as? String == email)
            #expect(try await list().body.string
                == #"{"identities":[{"provider":"github","providerEmail":"\#(email)"}],"passwordConfigured":true}"#)
            #expect(try await me()["profileSetupProvider"] as? String == "github")

            let secondLink = try await link("google", code: "link-google")
            #expect(secondLink.status == .ok)
            #expect(try await list().body.string
                == #"{"identities":[{"provider":"github","providerEmail":"\#(email)"},{"provider":"google","providerEmail":"\#(email)"}],"passwordConfigured":true}"#)
            #expect(try await me()["profileSetupProvider"] as? String == "github")

            // Deleting the first identity removes it from the one owner: the
            // list and profileSetupProvider both advance to the remaining row.
            let firstUnlink = try await unlink("github")
            #expect(firstUnlink.status == .ok)
            #expect(firstUnlink.body.string
                == #"{"unlinked":true,"identities":[{"provider":"google","providerEmail":"\#(email)"}],"passwordConfigured":true}"#)
            #expect(try await list().body.string
                == #"{"identities":[{"provider":"google","providerEmail":"\#(email)"}],"passwordConfigured":true}"#)
            #expect(try await me()["profileSetupProvider"] as? String == "google")

            let lastUnlink = try await unlink("google")
            #expect(lastUnlink.status == .ok)
            #expect(lastUnlink.body.string == #"{"unlinked":true,"identities":[],"passwordConfigured":true}"#)
            #expect(try await list().body.string == #"{"identities":[],"passwordConfigured":true}"#)
            #expect(try await me()["profileSetupProvider"] is NSNull)

            // A replay is idempotent and publishes the retained empty list.
            #expect(try await unlink("google").body.string
                == #"{"unlinked":false,"identities":[],"passwordConfigured":true}"#)
        }
    }
}

@Test func newSocialSignUpListsTheVerifiedProviderIdentityAndSetupProvider() async throws {
    let accounts = EmailLoginDirectory()
    let email = "social-signup-owner@slock.test"
    accounts.addSocialCompletion(
        provider: "github", code: "signup-github", email: email,
        mode: "login", intendedAction: "login", providerUserId: "github-signup-subject"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            let body = #"{"code":"signup-github","acceptTerms":true,"termsVersion":"\#(AuthLegalPolicy.termsVersion)","privacyVersion":"\#(AuthLegalPolicy.privacyVersion)"}"#
            let completed = try await ownerSend(client, .post, "/api/auth/github/complete", body: body)
            #expect(completed.status == .ok)
            let completedBody = ownerJSON(completed)
            let accessToken = try #require(completedBody["accessToken"] as? String)
            #expect(completedBody["linkedProvider"] == nil)

            // Upstream `createSocialUser` inserts the provider row in the same
            // transaction, so the new account's identity list is not empty and
            // its setup provider is the provider that created it.
            let listed = try await ownerSend(client, .get, "/api/auth/identities", bearer: accessToken)
            #expect(listed.body.string
                == #"{"identities":[{"provider":"github","providerEmail":"\#(email)"}],"passwordConfigured":false}"#)
            let me = ownerJSON(try await ownerSend(client, .get, "/api/auth/me", bearer: accessToken))
            #expect(me["profileSetupProvider"] as? String == "github")
            #expect(me["email"] as? String == email)
        }
    }
}
