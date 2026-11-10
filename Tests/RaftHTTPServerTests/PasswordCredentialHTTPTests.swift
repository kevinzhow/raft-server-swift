import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func passwordJSON(_ client: any Client, _ method: HTTPRequest.Method, _ path: String,
                          _ body: [String: String] = [:], token: String? = nil) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let token { headers[.authorization] = "Bearer \(token)" }
    let bytes = try JSONSerialization.data(withJSONObject: body)
    return try await client.send(method, headers: headers, to: URI(string: path)) {
        if method != .get { $0.body = .init(data: bytes) }
    }
}

private func passwordBody(_ response: ClientResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
}

private func passwordServices(_ accounts: EmailLoginDirectory) -> FallbackServices {
    FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts)
}

@Test func passwordProofPrecedesPendingLinkErrors() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: "password-precedence-user", email: "precedence@example.com", password: "correct-password")
    try await withApp { app in
        configure(app, services: passwordServices(accounts))
        try await app.testing { client in
            let response = try await passwordJSON(client, .post, "/api/auth/login", [
                "email": "precedence@example.com", "password": "wrong-password", "pendingLinkToken": "unknown-synthetic-link"
            ])
            #expect(response.status == .unauthorized)
            #expect(response.body.string == "{\"code\":\"AUTH_INVALID_CREDENTIALS\",\"error\":\"Invalid email or password\"}")
        }
    }
}

@Test func passwordChangeRevokesEveryAccessAndRefreshSession() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: "password-change-user", email: "change@example.com", password: "before-password")
    try await withApp { app in
        configure(app, services: passwordServices(accounts))
        try await app.testing { client in
            var sessions: [[String: Any]] = []
            for _ in 0..<2 {
                let response = try await passwordJSON(client, .post, "/api/auth/login", ["email": "change@example.com", "password": "before-password"])
                #expect(response.status == .ok)
                sessions.append(try passwordBody(response))
            }
            let access = try #require(sessions[0]["accessToken"] as? String)
            let changed = try await passwordJSON(client, .patch, "/api/auth/me", ["currentPassword": "before-password", "newPassword": "after-password"], token: access)
            #expect(changed.status == .ok)
            for session in sessions {
                let token = try #require(session["accessToken"] as? String)
                let me = try await passwordJSON(client, .get, "/api/auth/me", token: token)
                #expect(me.status == .unauthorized)
                let refresh = try await passwordJSON(client, .post, "/api/auth/refresh", ["refreshToken": try #require(session["refreshToken"] as? String)])
                #expect(refresh.status == .unauthorized)
            }
            let old = try await passwordJSON(client, .post, "/api/auth/login", ["email": "change@example.com", "password": "before-password"])
            #expect(old.status == .unauthorized)
            let fresh = try await passwordJSON(client, .post, "/api/auth/login", ["email": "change@example.com", "password": "after-password"])
            #expect(fresh.status == .ok)
        }
    }
}

@Test func passwordResetConsumesAllOutstandingResetTokensAndRevokesSessions() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "password-reset-user"
    accounts.addAccount(id: userId, email: "reset@example.com", password: "before-password")
    // Known synthetic token seeds; acceptance consumes them through the real HTTP
    // route. No private raw-token readback or delivery/query spy is used.
    for token in ["synthetic-reset-one", "synthetic-reset-two"] {
        accounts.authProfileStore.setResetToken(hash: AuthTokenCodec.sha256(token), userId: userId, expiresAt: Date().addingTimeInterval(3600))
    }
    try await withApp { app in
        configure(app, services: passwordServices(accounts))
        try await app.testing { client in
            let login = try await passwordJSON(client, .post, "/api/auth/login", ["email": "reset@example.com", "password": "before-password"])
            let session = try passwordBody(login)
            let reset = try await passwordJSON(client, .post, "/api/auth/reset-password", ["token": "synthetic-reset-one", "password": "reset-password"])
            #expect(reset.status == .ok)
            #expect(reset.body.string == "{\"ok\":true}")
            for token in ["synthetic-reset-one", "synthetic-reset-two"] {
                let replay = try await passwordJSON(client, .post, "/api/auth/reset-password", ["token": token, "password": "attacker-password"])
                #expect(replay.status == .badRequest)
                #expect(replay.body.string == "{\"error\":\"Invalid or expired reset token\"}")
            }
            let oldAccess = try #require(session["accessToken"] as? String)
            let me = try await passwordJSON(client, .get, "/api/auth/me", token: oldAccess)
            #expect(me.status == .unauthorized)
            let refresh = try await passwordJSON(client, .post, "/api/auth/refresh", ["refreshToken": try #require(session["refreshToken"] as? String)])
            #expect(refresh.status == .unauthorized)
            let fresh = try await passwordJSON(client, .post, "/api/auth/login", ["email": "reset@example.com", "password": "reset-password"])
            #expect(fresh.status == .ok)
        }
    }
}

// Imported Node credential: upstream node-argon2 test.cjs, commit
// 23b62102615421ef49618ed3307870f868a38852 (password = "password").
private let passwordNodeGolden = "$argon2id$v=19$m=65536,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA$rBWULD5jOGpQy32rLvGcmvQMVqIVNAmrCtekWvUA8bw"

private func passwordSeedPHC(_ accounts: EmailLoginDirectory, email: String, encoded: String) {
    accounts.authProfileStore.state.withLock { state in
        state.accountSurface.accounts[email] = Account(
            id: "synthetic-\(email)", email: email, passwordHash: encoded,
            displayLanguage: nil, name: "synthetic-password-user", profileSetupSuggestedHandle: nil
        )
    }
}

@Test func passwordLoginAcceptsAnImportedNodeArgon2idPHC() async throws {
    let accounts = EmailLoginDirectory()
    passwordSeedPHC(accounts, email: "node-golden@example.com", encoded: passwordNodeGolden)
    try await withApp { app in
        configure(app, services: passwordServices(accounts))
        try await app.testing { client in
            let result = try await passwordJSON(client, .post, "/api/auth/login", ["email": "node-golden@example.com", "password": "password"])
            #expect(result.status == .ok)
            #expect((try passwordBody(result)["accessToken"] as? String)?.isEmpty == false)
            let wrong = try await passwordJSON(client, .post, "/api/auth/login", ["email": "node-golden@example.com", "password": "wrong-password"])
            #expect(wrong.status == .unauthorized)
        }
    }
}

@Test func passwordLegacySHARejectsBothPlaintextAndDigestThenNormalResetMigrates() async throws {
    let accounts = EmailLoginDirectory()
    let email = "legacy-password@example.com"
    let digest = AuthTokenCodec.sha256("legacy-password")
    passwordSeedPHC(accounts, email: email, encoded: digest)
    accounts.authProfileStore.setResetToken(hash: AuthTokenCodec.sha256("synthetic-migration-reset"), userId: "synthetic-\(email)", expiresAt: Date().addingTimeInterval(60))
    try await withApp { app in
        configure(app, services: passwordServices(accounts))
        try await app.testing { client in
            for attempted in ["legacy-password", digest] {
                let rejected = try await passwordJSON(client, .post, "/api/auth/login", ["email": email, "password": attempted])
                #expect(rejected.status == .unauthorized)
                #expect(rejected.body.string == "{\"code\":\"AUTH_INVALID_CREDENTIALS\",\"error\":\"Invalid email or password\"}")
            }
            let reset = try await passwordJSON(client, .post, "/api/auth/reset-password", ["token": "synthetic-migration-reset", "password": "migrated-password"])
            #expect(reset.status == .ok)
            let login = try await passwordJSON(client, .post, "/api/auth/login", ["email": email, "password": "migrated-password"])
            #expect(login.status == .ok)
        }
    }
}

@Test func passwordAdmissionRejectsOverflowWithRedacted503() async throws {
    let accounts = EmailLoginDirectory()
    passwordSeedPHC(accounts, email: "capacity@example.com", encoded: passwordNodeGolden)
    try await withApp { app in
        configure(app, services: passwordServices(accounts))
        try await app.testing { client in
            let responses = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for _ in 0..<128 {
                    group.addTask {
                        let result = try await passwordJSON(client, .post, "/api/auth/login", ["email": "capacity@example.com", "password": "password"])
                        return (Int(result.status.code), result.body.string ?? "")
                    }
                }
                var responses: [(Int, String)] = []
                for try await response in group { responses.append(response) }
                return responses
            }
            #expect(responses.contains { $0.0 == 200 })
            #expect(responses.contains { $0.0 == 503 })
            #expect(responses.allSatisfy { $0.0 == 200 || $0.0 == 503 })
            for response in responses where response.0 == 503 {
                #expect(response.1 == "{\"error\":\"Password authentication temporarily unavailable\"}")
                #expect(!response.1.contains("$argon2"))
                #expect(!response.1.contains("capacity@example.com"))
            }
        }
    }
}
