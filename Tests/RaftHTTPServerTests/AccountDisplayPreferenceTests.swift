import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func accountDisplayPreferencesRoundTripAndValidate() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111627"
    accounts.addAccount(id: userId, email: "preferred-language@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            func me(_ method: String, _ body: String? = nil) async throws -> (ClientResponse, [String: Any]) {
                let response = try await client.send(method == "PATCH" ? .patch : .get, headers: headers, to: URI(string: "/api/auth/me")) { request in
                    if let body { request.body = .init(string: body) }
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let patched = try await me("PATCH", "{\"preferredLanguage\":\"zh-CN\",\"preferredTimezone\":\"Asia/Shanghai\",\"preferredTranslationMode\":\"manual\",\"preferredTranslationDisplay\":\"bilingual\",\"preferredTimeFormat\":\"24H\",\"preferredMessageBodyFontSize\":\"LG\"}")
            #expect(patched.0.status == .ok)
            #expect(patched.1["preferredLanguage"] as? String == "zh-cn")
            #expect(patched.1["preferredTimezone"] as? String == "Asia/Shanghai")
            #expect(patched.1["preferredTranslationMode"] as? String == "manual")
            #expect(patched.1["autoTranslationEnabled"] as? Bool == false)
            #expect(patched.1["preferredTranslationDisplay"] as? String == "bilingual")
            #expect(patched.1["preferredTimeFormat"] as? String == "24h")
            #expect(patched.1["preferredMessageBodyFontSize"] as? String == "lg")

            let read = try await me("GET")
            #expect(read.1["preferredLanguage"] as? String == "zh-cn")
            #expect(read.1["preferredTimezone"] as? String == "Asia/Shanghai")
            #expect(read.1["preferredTranslationMode"] as? String == "manual")
            #expect(read.1["preferredTranslationDisplay"] as? String == "bilingual")

            let cleared = try await me("PATCH", "{\"preferredLanguage\":null,\"preferredTimezone\":null,\"preferredTimeFormat\":null,\"preferredMessageBodyFontSize\":null}")
            #expect(cleared.0.status == .ok)
            #expect(cleared.1["preferredLanguage"] is NSNull)
            #expect(cleared.1["preferredTimezone"] is NSNull)
            #expect(cleared.1["preferredTimeFormat"] is NSNull)
            #expect(cleared.1["preferredMessageBodyFontSize"] is NSNull)

            let invalidTimezone = try await me("PATCH", "{\"preferredTimezone\":\"Not/A_Timezone\"}")
            #expect(invalidTimezone.0.status == .badRequest)
            let invalidFont = try await me("PATCH", "{\"preferredMessageBodyFontSize\":\"huge\"}")
            #expect(invalidFont.0.status == .badRequest)
            let invalidLanguage = try await me("PATCH", "{\"preferredLanguage\":\"not-a-language\"}")
            #expect(invalidLanguage.0.status == .badRequest)
            let invalidMode = try await me("PATCH", "{\"preferredTranslationMode\":\"always\"}")
            #expect(invalidMode.0.status == .badRequest)
            let invalidAuto = try await me("PATCH", "{\"autoTranslationEnabled\":null}")
            #expect(invalidAuto.0.status == .badRequest)
            let invalidDisplay = try await me("PATCH", "{\"preferredTranslationDisplay\":\"auto\"}")
            #expect(invalidDisplay.0.status == .badRequest)
            let invalidTime = try await me("PATCH", "{\"preferredTimeFormat\":\"military\"}")
            #expect(invalidTime.0.status == .badRequest)
        }
    }
}

@Test func newAccountHasOffTranslationDefaults() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111628"
    accounts.addAccount(id: userId, email: "translation-default@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            let response = try await client.get(URI(string: "/api/auth/me"), headers: headers)
            let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(response.status == .ok)
            #expect(body["preferredTranslationMode"] as? String == "off")
            #expect(body["autoTranslationEnabled"] as? Bool == false)
        }
    }
}

@Test func referralSourcePreferencesRoundTrip() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111629"
    accounts.addAccount(id: userId, email: "referral-source@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            func patch(_ body: String) async throws -> (ClientResponse, [String: Any]) {
                let response = try await client.send(.patch, headers: headers, to: URI(string: "/api/auth/me")) { request in
                    request.body = .init(string: body)
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let sourced = try await patch("{\"referralSource\":\"other\",\"referralSourceOther\":\"Vancouver meetup\"}")
            #expect(sourced.0.status == .ok)
            #expect(sourced.1["referralSource"] as? String == "other")
            #expect(sourced.1["referralSourceOther"] as? String == "Vancouver meetup")
            #expect(sourced.1["referralSourceSkippedAt"] is NSNull)

            let skipped = try await patch("{\"referralSourceSkipped\":true}")
            #expect(skipped.0.status == .ok)
            #expect(skipped.1["referralSource"] as? String == "other")
            #expect((skipped.1["referralSourceSkippedAt"] as? String)?.isEmpty == false)

            let invalid = try await patch("{\"referralSource\":\"wechat\"}")
            #expect(invalid.0.status == .badRequest)
        }
    }
}
