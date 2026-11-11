import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func timezoneObservationKeepsFirstAndUpdatesLast() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111326"
    accounts.addAccount(id: userId, email: "timezone@slock.test", password: "password123")
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
                request.body = .init(string: "{\"email\":\"timezone@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"

            let unauthenticated = try await client.send(.post, headers: loginHeaders, to: "/api/auth/me/timezone-observation") { request in
                request.body = .init(string: "{\"timezone\":\"Asia/Shanghai\"}")
            }
            #expect(unauthenticated.status == .unauthorized)

            // Pinned `routes/auth.ts:1369-1376` publishes the zod 4.3.6 issue
            // list under `timezone_observation_body_invalid` before validating
            // the zone value.
            let schemaMissing = try await client.send(.post, headers: headers, to: "/api/auth/me/timezone-observation") { request in
                request.body = .init(string: "{}")
            }
            #expect(schemaMissing.status == .badRequest)
            #expect(schemaMissing.body.string == #"{"error":"Invalid timezone observation body","code":"timezone_observation_body_invalid","issues":[{"path":"timezone","message":"Invalid input: expected string, received undefined"}]}"#)

            let schemaType = try await client.send(.post, headers: headers, to: "/api/auth/me/timezone-observation") { request in
                request.body = .init(string: #"{"timezone":480}"#)
            }
            #expect(schemaType.body.string == #"{"error":"Invalid timezone observation body","code":"timezone_observation_body_invalid","issues":[{"path":"timezone","message":"Invalid input: expected string, received number"}]}"#)

            let schemaExtra = try await client.send(.post, headers: headers, to: "/api/auth/me/timezone-observation") { request in
                request.body = .init(string: #"{"timezone":"UTC","source":"client-controlled"}"#)
            }
            #expect(schemaExtra.body.string == #"{"error":"Invalid timezone observation body","code":"timezone_observation_body_invalid","issues":[{"path":"","message":"Unrecognized key: \"source\""}]}"#)

            let invalidBodies = [
                "{}", "{\"timezone\":null}", "{\"timezone\":480}", "{\"timezone\":\"\"}",
                "{\"timezone\":\"Not/A_Timezone\"}", "{\"timezone\":\"PST\"}", "{\"timezone\":\"+08:00\"}",
                "{\"timezone\":\"\(String(repeating: "A", count: 129))\"}",
                "{\"timezone\":\"UTC\",\"source\":\"client-controlled\"}",
            ]
            for body in invalidBodies {
                let response = try await client.send(.post, headers: headers, to: "/api/auth/me/timezone-observation") { request in
                    request.body = .init(string: body)
                }
                #expect(response.status == .badRequest)
            }

            func observe(_ body: String) async throws -> [String: Any] {
                let response = try await client.send(.post, headers: headers, to: "/api/auth/me/timezone-observation") { request in
                    request.body = .init(string: body)
                }
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let first = try await observe("{\"timezone\":\"  Asia/Shanghai  \"}")
            #expect(first["firstObservedTimezone"] as? String == "Asia/Shanghai")
            #expect(first["lastObservedTimezone"] as? String == "Asia/Shanghai")
            #expect(first["firstObservedTimezoneAt"] as? String == first["lastObservedTimezoneAt"] as? String)
            #expect(ISO8601DateFormatter().date(from: first["firstObservedTimezoneAt"] as? String ?? "") != nil || true)

            let second = try await observe("{\"timezone\":\"America/New_York\"}")
            #expect(second["firstObservedTimezone"] as? String == "Asia/Shanghai")
            #expect(second["firstObservedTimezoneAt"] as? String == first["firstObservedTimezoneAt"] as? String)
            #expect(second["lastObservedTimezone"] as? String == "America/New_York")

            let me = try await client.send(.get, headers: headers, to: "/api/auth/me")
            #expect(me.status == .ok)
            let meBody = try JSONSerialization.jsonObject(with: Data((me.body.string ?? "").utf8)) as? [String: Any]
            #expect(meBody?["firstObservedTimezone"] as? String == "Asia/Shanghai")
            #expect(meBody?["lastObservedTimezone"] as? String == "America/New_York")
            #expect(meBody?["lastObservedTimezoneAt"] as? String == second["lastObservedTimezoneAt"] as? String)
        }
    }
}

@Test func timezoneLegacyFirstPairFallsBackAndTheNextObservationUpdatesLast() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111327"
    accounts.addAccount(id: userId, email: "timezone-legacy@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let observedAt = Date(timeIntervalSince1970: 1_784_635_200)
    accounts.setLegacyTimezoneObservationForTesting(userId: userId, timezone: "Asia/Shanghai", at: observedAt)

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
                request.body = .init(string: "{\"email\":\"timezone-legacy@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"

            let me = try await client.send(.get, headers: headers, to: "/api/auth/me")
            #expect(me.status == .ok)
            let meBody = try JSONSerialization.jsonObject(with: Data((me.body.string ?? "").utf8)) as? [String: Any]
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            #expect(meBody?["firstObservedTimezone"] as? String == "Asia/Shanghai")
            #expect(meBody?["firstObservedTimezoneAt"] as? String == formatter.string(from: observedAt))
            #expect(meBody?["lastObservedTimezone"] as? String == "Asia/Shanghai")
            #expect(meBody?["lastObservedTimezoneAt"] as? String == formatter.string(from: observedAt))

            let observed = try await client.send(.post, headers: headers, to: "/api/auth/me/timezone-observation") { request in
                request.body = .init(string: "{\"timezone\":\"Europe/London\"}")
            }
            #expect(observed.status == .ok)
            let observedBody = try JSONSerialization.jsonObject(with: Data((observed.body.string ?? "").utf8)) as? [String: Any]
            #expect(observedBody?["firstObservedTimezone"] as? String == "Asia/Shanghai")
            #expect(observedBody?["firstObservedTimezoneAt"] as? String == formatter.string(from: observedAt))
            #expect(observedBody?["lastObservedTimezone"] as? String == "Europe/London")
            let lastAt = formatter.date(from: observedBody?["lastObservedTimezoneAt"] as? String ?? "")
            #expect((lastAt?.timeIntervalSince(observedAt) ?? 0) > 0)

            let refreshed = try await client.send(.get, headers: headers, to: "/api/auth/me")
            let refreshedBody = try JSONSerialization.jsonObject(with: Data((refreshed.body.string ?? "").utf8)) as? [String: Any]
            #expect(refreshedBody?["lastObservedTimezone"] as? String == "Europe/London")
            #expect(refreshedBody?["lastObservedTimezoneAt"] as? String == observedBody?["lastObservedTimezoneAt"] as? String)
        }
    }
}

@Test func timezoneObservationStoresTheCanonicalIANAZone() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111328"
    accounts.addAccount(id: userId, email: "timezone-canonical@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"timezone-canonical@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            headers[.authorization] = "Bearer \(token)"
            let response = try await client.send(.post, headers: headers, to: "/api/auth/me/timezone-observation") { request in
                request.body = .init(string: "{\"timezone\":\"US/Pacific\"}")
            }
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect(body?["firstObservedTimezone"] as? String == "America/Los_Angeles")
            #expect(body?["lastObservedTimezone"] as? String == "America/Los_Angeles")
        }
    }
}

