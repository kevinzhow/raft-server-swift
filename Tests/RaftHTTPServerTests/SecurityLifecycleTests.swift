import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func lifecycleAccounts(_ email: String, _ userId: String) -> EmailLoginDirectory {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: userId, email: email, password: "password123")
    accounts.markEmailVerified(userId: userId)
    return accounts
}

@Test func familyRevokeClosesHTTPAccessAndStaysIdempotentWithinRetention() async throws {
    let accounts = lifecycleAccounts("family-revoke@security.test", "11111111-1111-4111-8111-000001086001")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/login")) { request in
                request.body = .init(string: "{\"email\":\"family-revoke@security.test\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let accessToken = try #require(body["accessToken"] as? String)
            let refreshToken = try #require(body["refreshToken"] as? String)
            let capability = try #require(accounts.mintFamilyRevokeCapabilityForTesting(refreshToken: refreshToken))

            var authHeaders = HTTPFields()
            authHeaders[.authorization] = "Bearer \(accessToken)"
            #expect((try await client.get(URI(string: "/api/auth/me"), headers: authHeaders)).status == .ok)

            let revoke = try await client.send(.post, headers: headers, to: URI(string: "/api/push/family-revoke")) { request in
                request.body = .init(string: "{\"capability\":\"\(capability)\"}")
            }
            #expect(revoke.status == .noContent)
            #expect((try await client.get(URI(string: "/api/auth/me"), headers: authHeaders)).status == .unauthorized)

            let revokeAgain = try await client.send(.post, headers: headers, to: URI(string: "/api/push/family-revoke")) { request in
                request.body = .init(string: "{\"capability\":\"\(capability)\"}")
            }
            #expect(revokeAgain.status == .noContent)
        }
    }
}

@Test func legacyPredecessorLogoutRevokesTheSuccessorFamily() async throws {
    let accounts = lifecycleAccounts("predecessor@security.test", "11111111-1111-4111-8111-000001086011")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/login")) { request in
                request.body = .init(string: "{\"email\":\"predecessor@security.test\",\"password\":\"password123\"}")
            }
            let first = try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let firstRefresh = try #require(first["refreshToken"] as? String)
            let refresh = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/refresh")) { request in
                request.body = .init(string: "{\"refreshToken\":\"\(firstRefresh)\"}")
            }
            #expect(refresh.status == .ok)
            let successor = try JSONSerialization.jsonObject(with: Data((refresh.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let successorRefresh = try #require(successor["refreshToken"] as? String)
            let successorAccess = try #require(successor["accessToken"] as? String)
            #expect(successorRefresh != firstRefresh)

            let logout = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/logout")) { request in
                request.body = .init(string: "{\"refreshToken\":\"\(firstRefresh)\"}")
            }
            #expect(logout.status == .ok)
            var authHeaders = HTTPFields()
            authHeaders[.authorization] = "Bearer \(successorAccess)"
            #expect((try await client.get(URI(string: "/api/auth/me"), headers: authHeaders)).status == .unauthorized)
            let replay = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/refresh")) { request in
                request.body = .init(string: "{\"refreshToken\":\"\(successorRefresh)\"}")
            }
            #expect(replay.status == .unauthorized)
        }
    }
}

@Test func logoutLineageSurvivesMultipleRotations() async throws {
    let accounts = lifecycleAccounts("lineage@security.test", "11111111-1111-4111-8111-000001086021")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/login")) { request in
                request.body = .init(string: "{\"email\":\"lineage@security.test\",\"password\":\"password123\"}")
            }
            let firstRefresh = try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            var refreshToken = try #require(firstRefresh["refreshToken"] as? String)
            let firstToken = refreshToken
            var lastAccess = ""
            for _ in 0..<2 {
                let refresh = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/refresh")) { request in
                    request.body = .init(string: "{\"refreshToken\":\"\(refreshToken)\"}")
                }
                #expect(refresh.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((refresh.body.string ?? "").utf8)) as? [String: Any] ?? [:]
                refreshToken = try #require(body["refreshToken"] as? String)
                lastAccess = try #require(body["accessToken"] as? String)
            }
            let staleRefresh = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/refresh")) { request in
                request.body = .init(string: "{\"refreshToken\":\"\(firstToken)\"}")
            }
            #expect(staleRefresh.status == .unauthorized)
            let logout = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/logout")) { request in
                request.body = .init(string: "{\"refreshToken\":\"\(firstToken)\"}")
            }
            #expect(logout.status == .ok)
            var authHeaders = HTTPFields()
            authHeaders[.authorization] = "Bearer \(lastAccess)"
            #expect((try await client.get(URI(string: "/api/auth/me"), headers: authHeaders)).status == .unauthorized)
            let lastRefresh = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/refresh")) { request in
                request.body = .init(string: "{\"refreshToken\":\"\(refreshToken)\"}")
            }
            #expect(lastRefresh.status == .unauthorized)
        }
    }
}

@Test func resetTokenCompletesOnlyOneConcurrentPasswordChange() async throws {
    let accounts = lifecycleAccounts("reset-race@security.test", "11111111-1111-4111-8111-000001086031")
    accounts.addPasswordResetTokenForTesting(userId: "11111111-1111-4111-8111-000001086031", token: "reset-token-race", expiresAt: Date().addingTimeInterval(600))
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            async let first: ClientResponse = client.send(.post, headers: headers, to: URI(string: "/api/auth/reset-password")) { request in
                request.body = .init(string: "{\"token\":\"reset-token-race\",\"password\":\"first-password\"}")
            }
            async let second: ClientResponse = client.send(.post, headers: headers, to: URI(string: "/api/auth/reset-password")) { request in
                request.body = .init(string: "{\"token\":\"reset-token-race\",\"password\":\"second-password\"}")
            }
            let responses = try await [first, second]
            #expect(responses.filter { $0.status == .ok }.count == 1)
            #expect(responses.filter { $0.status == .badRequest }.count == 1)
            let winningPassword = responses[0].status == .ok ? "first-password" : "second-password"
            let login = try await client.send(.post, headers: headers, to: URI(string: "/api/auth/login")) { request in
                request.body = .init(string: "{\"email\":\"reset-race@security.test\",\"password\":\"\(winningPassword)\"}")
            }
            #expect(login.status == .ok)
        }
    }
}
