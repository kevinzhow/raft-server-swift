import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func accountReferralSourceCanBeRecordedAndSkipped() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111464"
    accounts.addAccount(id: userId, email: "referral-source@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"referral-source@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            func patch(_ body: String) async throws -> ([String: Any], Int) {
                let response = try await client.send(.patch, headers: headers, to: "/api/auth/me") { request in
                    request.body = .init(string: body)
                }
                let object = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                return (object, response.status.code)
            }

            let recorded = try await patch("{\"referralSource\":\"other\",\"referralSourceOther\":\"Vancouver meetup\"}")
            #expect(recorded.1 == 200)
            #expect(recorded.0["referralSource"] as? String == "other")
            #expect(recorded.0["referralSourceOther"] as? String == "Vancouver meetup")
            #expect(recorded.0["referralSourceSkippedAt"] == nil || recorded.0["referralSourceSkippedAt"] is NSNull)

            let skipped = try await patch("{\"referralSourceSkipped\":true}")
            #expect(skipped.1 == 200)
            #expect(skipped.0["referralSource"] as? String == "other")
            #expect(skipped.0["referralSourceOther"] as? String == "Vancouver meetup")
            #expect((skipped.0["referralSourceSkippedAt"] as? String)?.isEmpty == false)

            #expect(try await patch("{\"referralSource\":\"wechat\"}").1 == 400)
            #expect(try await patch("{\"referralSourceOther\":\"orphan\"}").1 == 400)
        }
    }
}
