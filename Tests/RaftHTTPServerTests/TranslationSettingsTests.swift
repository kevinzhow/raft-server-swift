import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Suite(.serialized)
struct TranslationSettingsSuite {
@Test func translationSettingsAreServerScopedWithOwnerAdminManagement() async throws {
    setenv("TRANSLATION_PROVIDER", "fake", 1)
    defer { unsetenv("TRANSLATION_PROVIDER") }
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111370"
    let adminId = "11111111-1111-4111-8111-111111111371"
    let memberId = "11111111-1111-4111-8111-111111111372"
    let serverId = "33333333-3333-4333-8333-333333333517"
    for (id, email) in [
        (ownerId, "translation-owner@slock.test"),
        (adminId, "translation-admin@slock.test"),
        (memberId, "translation-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "translation-settings", name: "Translation", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func get(_ token: String) async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers(token), to: "/api/servers/\(serverId)/translation-settings")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func patch(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers(token), to: "/api/servers/\(serverId)/translation-settings") { request in
                    request.body = .init(string: body)
                }
            }
            let ownerToken = try await login("translation-owner@slock.test")
            let adminToken = try await login("translation-admin@slock.test")
            let memberToken = try await login("translation-member@slock.test")

            let ownerView = try await get(ownerToken)
            #expect(ownerView["translationEnabled"] as? Bool == false)
            #expect(ownerView["translationAvailable"] as? Bool == true)
            #expect(ownerView["canManageTranslation"] as? Bool == true)
            let memberView = try await get(memberToken)
            #expect(memberView["canManageTranslation"] as? Bool == false)

            let memberPatch = try await patch(memberToken, "{\"translationEnabled\":true}")
            #expect(memberPatch.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((memberPatch.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Only server owners and admins can update translation settings")

            let invalid = try await patch(ownerToken, "{\"translationEnabled\":\"yes\"}")
            #expect(invalid.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((invalid.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "translationEnabled must be a boolean")

            #expect(try JSONSerialization.jsonObject(with: Data((try await patch(adminToken, "{\"translationEnabled\":true}").body.string ?? "").utf8)) as? [String: Any] != nil)
            let enabled = try await patch(adminToken, "{\"translationEnabled\":true}")
            let enabledBody = try JSONSerialization.jsonObject(with: Data((enabled.body.string ?? "").utf8)) as? [String: Any]
            #expect(enabledBody?["translationEnabled"] as? Bool == true)
            let disabled = try await patch(ownerToken, "{\"translationEnabled\":false}")
            let disabledBody = try JSONSerialization.jsonObject(with: Data((disabled.body.string ?? "").utf8)) as? [String: Any]
            #expect(disabledBody?["translationEnabled"] as? Bool == false)
        }
    }
}

@Test func translationAvailabilityFollowsProviderCredentials() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111373"
    let serverId = "33333333-3333-4333-8333-333333333518"
    accounts.addAccount(id: ownerId, email: "translation-provider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "translation-provider", name: "Translation Provider", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"translation-provider@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func available() async throws -> Bool? {
                let response = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/translation-settings")
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return body?["translationAvailable"] as? Bool
            }

            func withEnv(_ values: [String: String], _ run: () async throws -> Void) async rethrows {
                var previous: [String: String?] = [:]
                for (key, value) in values {
                    previous[key] = ProcessInfo.processInfo.environment[key]
                    setenv(key, value, 1)
                }
                defer {
                    for (key, value) in previous {
                        if let value { setenv(key, value, 1) } else { unsetenv(key) }
                    }
                }
                try await run()
            }

            try await withEnv(["TRANSLATION_PROVIDER": "volcengine", "TRANSLATION_VOLCENGINE_ACCESS_KEY_ID": "ak", "TRANSLATION_VOLCENGINE_SECRET_ACCESS_KEY": "sk"]) {
                let value = try await available()
                #expect(value == true)
            }
            try await withEnv(["TRANSLATION_PROVIDER": "volcengine", "TRANSLATION_VOLCENGINE_ACCESS_KEY_ID": "", "TRANSLATION_VOLCENGINE_SECRET_ACCESS_KEY": ""]) {
                let value = try await available()
                #expect(value == false)
            }
            try await withEnv(["TRANSLATION_PROVIDER": "google", "TRANSLATION_GOOGLE_PROJECT_ID": "p", "TRANSLATION_GOOGLE_ACCESS_TOKEN": "t"]) {
                let value = try await available()
                #expect(value == true)
            }
            try await withEnv(["TRANSLATION_PROVIDER": "google", "TRANSLATION_GOOGLE_PROJECT_ID": "p", "TRANSLATION_GOOGLE_ACCESS_TOKEN": ""]) {
                let value = try await available()
                #expect(value == false)
            }
        }
    }
}
}
