import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func accountDisplayPreferencesRoundTripAndValidate() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111463"
    accounts.addAccount(id: userId, email: "preferred-language@slock.test", password: "password123")
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
                request.body = .init(string: "{\"email\":\"preferred-language@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"

            let defaults = try await client.send(.get, headers: headers, to: "/api/auth/me")
            let defaultsBody = try JSONSerialization.jsonObject(with: Data((defaults.body.string ?? "").utf8)) as? [String: Any]
            #expect(defaultsBody?["preferredTranslationMode"] as? String == "off")
            #expect(defaultsBody?["autoTranslationEnabled"] as? Bool == false)

            func patch(_ body: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers, to: "/api/auth/me") { request in
                    request.body = .init(string: body)
                }
            }
            let update = try await patch("{\"preferredLanguage\":\"zh-CN\",\"preferredTimezone\":\"Asia/Shanghai\",\"preferredTranslationMode\":\"manual\",\"preferredTranslationDisplay\":\"bilingual\",\"preferredTimeFormat\":\"24H\",\"preferredMessageBodyFontSize\":\"LG\"}")
            #expect(update.status == .ok)
            let updated = try JSONSerialization.jsonObject(with: Data((update.body.string ?? "").utf8)) as? [String: Any]
            #expect(updated?["preferredLanguage"] as? String == "zh-cn")
            #expect(updated?["preferredTimezone"] as? String == "Asia/Shanghai")
            #expect(updated?["preferredTranslationMode"] as? String == "manual")
            #expect(updated?["autoTranslationEnabled"] as? Bool == false)
            #expect(updated?["preferredTranslationDisplay"] as? String == "bilingual")
            #expect(updated?["preferredTimeFormat"] as? String == "24h")
            #expect(updated?["preferredMessageBodyFontSize"] as? String == "lg")

            let persisted = try await client.send(.get, headers: headers, to: "/api/auth/me")
            let persistedBody = try JSONSerialization.jsonObject(with: Data((persisted.body.string ?? "").utf8)) as? [String: Any]
            #expect(persistedBody?["preferredLanguage"] as? String == "zh-cn")
            #expect(persistedBody?["preferredTimezone"] as? String == "Asia/Shanghai")

            let cleared = try await patch("{\"preferredLanguage\":null,\"preferredTimezone\":null,\"preferredTimeFormat\":null,\"preferredMessageBodyFontSize\":null}")
            #expect(cleared.status == .ok)
            let clearedBody = try JSONSerialization.jsonObject(with: Data((cleared.body.string ?? "").utf8)) as? [String: Any]
            #expect(clearedBody?["preferredLanguage"] == nil || clearedBody?["preferredLanguage"] is NSNull)
            #expect(clearedBody?["preferredTimezone"] == nil || clearedBody?["preferredTimezone"] is NSNull)

            for invalid in [
                "{\"preferredTimezone\":\"Not/A_Timezone\"}",
                "{\"preferredMessageBodyFontSize\":\"huge\"}",
                "{\"preferredLanguage\":\"not-a-language\"}",
                "{\"preferredTranslationMode\":\"always\"}",
                "{\"autoTranslationEnabled\":null}",
                "{\"preferredTranslationDisplay\":\"auto\"}",
                "{\"preferredTimeFormat\":\"military\"}",
            ] {
                #expect(try await patch(invalid).status == .badRequest)
            }
        }
    }
}
