import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func familyRevokeIsUnauthenticatedIdempotentAndTerminalAfterRetention() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111252"
    let serverId = "33333333-3333-4333-8333-333333333447"
    accounts.addAccount(id: ownerId, email: "push-family@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "push-family-api", name: "Push Family API", ownerId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var jsonHeaders = HTTPFields()
            jsonHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: jsonHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"push-family@slock.test\",\"password\":\"password123\"}")
            }
            let session = try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any]
            let accessToken = session?["accessToken"] as? String ?? ""
            let refreshToken = session?["refreshToken"] as? String ?? ""

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accessToken)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func register(_ token: String, deviceToken: String) async throws -> ClientResponse {
                var requestHeaders = headers
                requestHeaders[.authorization] = "Bearer \(token)"
                return try await client.send(.post, headers: requestHeaders, to: "/api/push/registrations") { request in
                    request.body = .init(string: "{\"installationId\":\"ios-family-install\",\"provider\":\"apns\",\"env\":\"production\",\"topic\":\"ai.slock.app\",\"deviceToken\":\"\(deviceToken)\"}")
                }
            }

            let registration = try await register(accessToken, deviceToken: "family-token")
            #expect(registration.status == .ok)
            let capability = (try JSONSerialization.jsonObject(with: Data((registration.body.string ?? "").utf8)) as? [String: Any])?["revoke_capability"] as? String ?? ""
            #expect(capability.split(separator: ".").count == 2)

            let refresh = try await client.send(.post, headers: jsonHeaders, to: "/api/auth/refresh") { request in
                request.body = .init(string: "{\"refreshToken\":\"\(refreshToken)\"}")
            }
            #expect(refresh.status == .ok)
            let rotated = try JSONSerialization.jsonObject(with: Data((refresh.body.string ?? "").utf8)) as? [String: Any]
            let rotatedAccess = rotated?["accessToken"] as? String ?? ""
            let afterRotation = try await register(rotatedAccess, deviceToken: "family-token-rotated")
            #expect((try JSONSerialization.jsonObject(with: Data((afterRotation.body.string ?? "").utf8)) as? [String: Any])?["revoke_capability"] as? String == capability)

            func revoke(_ capability: String) async throws -> ClientResponse {
                try await client.send(.post, headers: jsonHeaders, to: "/api/push/family-revoke") { request in
                    request.body = .init(string: "{\"capability\":\"\(capability)\"}")
                }
            }

            #expect(try await revoke(capability).status == .noContent)
            let status = accounts.pushFamilyStatus(capability: capability)
            #expect(status?.revoked == true)
            #expect(status?.reason == "push_family")
            #expect(status?.retainUntil?.timeIntervalSinceNow ?? 0 > 29 * 24 * 60 * 60)
            #expect(try await revoke(capability).status == .noContent)

            accounts.expirePushFamilyCapability(capability: capability)
            #expect(try await revoke(capability).status == .forbidden)

            let tampered = String(capability.dropLast()) + "x"
            #expect(try await revoke(tampered).status == .forbidden)
            #expect(try await revoke("bad capability").status == .badRequest)

            let secondLogin = try await client.send(.post, headers: jsonHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"push-family@slock.test\",\"password\":\"password123\"}")
            }
            let secondSession = try JSONSerialization.jsonObject(with: Data((secondLogin.body.string ?? "").utf8)) as? [String: Any]
            let secondAccess = secondSession?["accessToken"] as? String ?? ""
            let secondRefresh = secondSession?["refreshToken"] as? String ?? ""
            let secondRegistration = try await register(secondAccess, deviceToken: "family-token-logout")
            let secondCapability = (try JSONSerialization.jsonObject(with: Data((secondRegistration.body.string ?? "").utf8)) as? [String: Any])?["revoke_capability"] as? String ?? ""
            #expect(secondCapability != capability)

            let logout = try await client.send(.post, headers: jsonHeaders, to: "/api/auth/logout") { request in
                request.body = .init(string: "{\"refreshToken\":\"\(secondRefresh)\"}")
            }
            #expect(logout.status == .ok)
            #expect(accounts.pushFamilyStatus(capability: secondCapability)?.reason == "logout")
            #expect(try await revoke(secondCapability).status == .noContent)
        }
    }
}
