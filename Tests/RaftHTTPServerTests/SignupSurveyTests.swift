import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

// Upstream `PATCH /api/auth/me` writes the signup survey role and its completion
// stamp together: `routes/auth.ts:1577-1584` validates the exact role ids and
// stamps one request time, and `services/userService.ts:54-96` publishes
// `signupSurveyCompletedAt` / `signupRole` on the user object. The survey is
// independent of the referral source it usually travels with, and neither
// `emailVerified` nor `profileSetupCompletedAt` implies that it was answered.

private func surveyAccount(_ idSuffix: String) -> (accounts: EmailLoginDirectory, userId: String, email: String) {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-1111111120\(idSuffix)"
    let email = "signup-survey-\(idSuffix)@slock.test"
    accounts.addAccount(id: userId, email: email, password: "password123")
    accounts.markEmailVerified(userId: userId)
    return (accounts, userId, email)
}

@Test func accountSignupSurveyRoleStampsTheRequestTimeAndNullClearsIt() async throws {
    let fixture = surveyAccount("11")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(fixture.email)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8))
                as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            func me() async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers, to: "/api/auth/me")
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func patch(_ body: String) async throws -> ([String: Any], Int, String) {
                let response = try await client.send(.patch, headers: headers, to: "/api/auth/me") { request in
                    request.body = .init(string: body)
                }
                let object = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                return (object, response.status.code, response.body.string ?? "")
            }

            // The fixture account is verified and profile-complete. Neither fact
            // answers the survey, and a referral-only PATCH does not either.
            let initial = try await me()
            #expect(initial["signupRole"] is NSNull)
            #expect(initial["signupSurveyCompletedAt"] is NSNull)
            let referralOnly = try await patch("{\"referralSource\":\"search\"}")
            #expect(referralOnly.1 == 200)
            #expect(referralOnly.0["signupSurveyCompletedAt"] is NSNull)
            let afterReferral = try await me()
            #expect(afterReferral["signupSurveyCompletedAt"] is NSNull)

            // A role alone is legal and stamps the request time in the same write.
            let recorded = try await patch("{\"signupRole\":\"engineering_leader\"}")
            #expect(recorded.1 == 200)
            #expect(recorded.0["signupRole"] as? String == "engineering_leader")
            let recordedAt = recorded.0["signupSurveyCompletedAt"] as? String ?? ""
            #expect(!recordedAt.isEmpty)
            #expect(recorded.0["referralSource"] as? String == "search")
            let afterRole = try await me()
            #expect(afterRole["signupRole"] as? String == "engineering_leader")
            #expect(afterRole["signupSurveyCompletedAt"] as? String == recordedAt)

            // Explicit null is a present key: it clears the role and stamps the
            // request that answered the survey with "no role".
            let cleared = try await patch("{\"signupRole\":null}")
            #expect(cleared.1 == 200)
            #expect(cleared.0["signupRole"] is NSNull)
            #expect(!((cleared.0["signupSurveyCompletedAt"] as? String) ?? "").isEmpty)
            #expect(cleared.0["referralSource"] as? String == "search")

            // An absent key never rewrites either survey fact.
            let untouchedAt = cleared.0["signupSurveyCompletedAt"] as? String
            let untouched = try await patch("{\"referralSourceSkipped\":true}")
            #expect(untouched.1 == 200)
            #expect(untouched.0["signupRole"] is NSNull)
            #expect(untouched.0["signupSurveyCompletedAt"] as? String == untouchedAt)
        }
    }
}

@Test func accountSignupSurveyInvalidsRejectWithoutWritingSurveyOrReferral() async throws {
    let fixture = surveyAccount("12")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(fixture.email)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8))
                as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            func me() async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers, to: "/api/auth/me")
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func patch(_ body: String) async throws -> ([String: Any], Int, String) {
                let response = try await client.send(.patch, headers: headers, to: "/api/auth/me") { request in
                    request.body = .init(string: body)
                }
                let object = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                return (object, response.status.code, response.body.string ?? "")
            }

            // Wrong case, untrimmed whitespace, unknown ids and every wrong JSON
            // type are the same 400 body.
            for body in [
                "{\"signupRole\":\"Software_Engineer\"}",
                "{\"signupRole\":\" software_engineer\"}",
                "{\"signupRole\":\"software_engineer \"}",
                "{\"signupRole\":\"student_or_learner\"}",
                "{\"signupRole\":1}",
                "{\"signupRole\":true}",
                "{\"signupRole\":{}}",
                "{\"signupRole\":[]}",
            ] {
                let rejected = try await patch(body)
                #expect(rejected.1 == 400, Comment(rawValue: body))
                #expect(rejected.2 == #"{"error":"Invalid signupRole"}"#, Comment(rawValue: body))
            }
            // A rejected role leaves the valid referral in the same body unwritten.
            _ = try await patch("{\"signupRole\":\"intern\",\"referralSource\":\"search\"}")
            let afterRejectedRole = try await me()
            #expect(afterRejectedRole["referralSource"] is NSNull)
            #expect(afterRejectedRole["signupRole"] is NSNull)
            #expect(afterRejectedRole["signupSurveyCompletedAt"] is NSNull)

            // A rejected referral leaves the valid role in the same body unwritten.
            let rejectedReferral = try await patch("{\"signupRole\":\"founder\",\"referralSource\":\"wechat\"}")
            #expect(rejectedReferral.1 == 400)
            #expect(rejectedReferral.2 == #"{"error":"Invalid referralSource"}"#)
            let afterRejectedReferral = try await me()
            #expect(afterRejectedReferral["referralSource"] is NSNull)
            #expect(afterRejectedReferral["signupRole"] is NSNull)
            #expect(afterRejectedReferral["signupSurveyCompletedAt"] is NSNull)

            // The API does not require the role and the referral together.
            #expect(try await patch("{\"signupRole\":\"founder\"}").1 == 200)
            let recorded = try await me()
            #expect(recorded["signupRole"] as? String == "founder")
            let recordedAt = recorded["signupSurveyCompletedAt"] as? String ?? ""
            #expect(!recordedAt.isEmpty)
            #expect(recorded["referralSource"] is NSNull)

            // The password change stays earlier than the survey validation: the
            // new credential is committed even though this request answers 400.
            let passwordRejected = try await patch(
                "{\"currentPassword\":\"password123\",\"newPassword\":\"longenough1\",\"signupRole\":\"intern\"}"
            )
            #expect(passwordRejected.1 == 400)
            #expect(passwordRejected.2 == #"{"error":"Invalid signupRole"}"#)
            let oldCredential = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(fixture.email)\",\"password\":\"password123\"}")
            }
            #expect(oldCredential.status.code == 401)
            let newCredential = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(fixture.email)\",\"password\":\"longenough1\"}")
            }
            #expect(newCredential.status.code == 200)
            let newToken = (try JSONSerialization.jsonObject(with: Data((newCredential.body.string ?? "").utf8))
                as? [String: Any])?["accessToken"] as? String ?? ""
            var newHeaders = HTTPFields()
            newHeaders[.authorization] = "Bearer \(newToken)"
            let afterPassword = try await client.send(.get, headers: newHeaders, to: "/api/auth/me")
            let afterPasswordBody = try JSONSerialization.jsonObject(
                with: Data((afterPassword.body.string ?? "").utf8)
            ) as? [String: Any] ?? [:]
            #expect(afterPasswordBody["signupRole"] as? String == "founder")
            #expect(afterPasswordBody["signupSurveyCompletedAt"] as? String == recordedAt)
        }
    }
}
