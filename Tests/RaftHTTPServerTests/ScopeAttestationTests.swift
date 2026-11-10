import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func scopeAttestationSignsTheScopeAudienceAndResource() async throws {
    let accounts = EmailLoginDirectory()
    accounts.setScopeAttestationSecretForTesting(AttestationClaims.secret)
    let ownerId = "11111111-1111-4111-8111-111111111310"
    let memberId = "11111111-1111-4111-8111-111111111311"
    let serverId = "33333333-3333-4333-8333-333333333483"
    accounts.addAccount(id: ownerId, email: "scope-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "scope-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "scope", name: "Scope", ownerId: ownerId)
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
            func attest(_ token: String, _ scope: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: "/api/servers/\(serverId)/scope-attestation") { request in
                    request.body = .init(string: "{\"scope\":\"\(scope)\",\"email\":\"forged@scope.test\",\"serverSlug\":\"forged\",\"traceUserId\":\"forged\"}")
                }
            }
            func payload(_ response: ClientResponse) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let ownerToken = try await login("scope-owner@slock.test")
            let memberToken = try await login("scope-member@slock.test")

            let trace = try await attest(memberToken, "web-trace-batch:create")
            #expect(trace.status == .ok)
            let traceBody = try payload(trace)
            #expect(traceBody["scope"] as? String == "web-trace-batch:create")
            #expect(traceBody["audience"] as? String == "trace-ingest-worker")
            #expect(traceBody["resource"] as? String == "servers/\(serverId)/web-traces")
            let expiryFormatter = ISO8601DateFormatter()
            expiryFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let traceExpiresAt = try #require(traceBody["expiresAt"] as? String)
            let traceExpiry = try #require(expiryFormatter.date(from: traceExpiresAt))
            #expect(traceExpiry > Date())
            let traceAttestation = traceBody["attestation"] as? String ?? ""
            #expect(traceAttestation.split(separator: ".", omittingEmptySubsequences: false).count == 2)
            let traceClaims = try #require(AttestationClaims.verifiedScopeClaims(traceAttestation))
            #expect(Set(traceClaims.keys) == Set([
                "v", "typ", "scope", "sub", "actorType", "traceUserId", "email", "serverId", "serverSlug",
                "aud", "resource", "nonce", "exp",
            ]))
            #expect(traceClaims["v"] as? Int == 1)
            #expect(traceClaims["typ"] as? String == "scope-attestation")
            #expect(traceClaims["email"] as? String == "scope-member@slock.test")
            #expect(traceClaims["serverSlug"] as? String == "scope")
            #expect(traceClaims["traceUserId"] is NSNull)
            #expect(UUID(uuidString: traceClaims["nonce"] as? String ?? "") != nil)
            #expect(AttestationClaims.verifiedScopeClaims(traceAttestation, secret: "wrong-key") == nil)
            #expect(traceClaims["scope"] as? String == "web-trace-batch:create")
            #expect(traceClaims["actorType"] as? String == "user")
            #expect(traceClaims["sub"] as? String == memberId)
            #expect(traceClaims["serverId"] as? String == serverId)
            #expect(traceClaims["aud"] as? String == "trace-ingest-worker")
            #expect(traceClaims["resource"] as? String == "servers/\(serverId)/web-traces")
            #expect((traceClaims["exp"] as? Int ?? 0) > Int(Date().timeIntervalSince1970))

            let memberFeedback = try await attest(memberToken, "feedback-report:create")
            #expect(memberFeedback.status == .forbidden)

            let ownerFeedback = try await attest(ownerToken, "feedback-report:create")
            #expect(ownerFeedback.status == .ok)
            let feedbackBody = try payload(ownerFeedback)
            #expect(feedbackBody["audience"] as? String == "feedback-worker")
            #expect(feedbackBody["resource"] as? String == "servers/\(serverId)/feedback-reports")
            let feedbackClaims = AttestationClaims.verifiedScopeClaims(feedbackBody["attestation"] as? String ?? "")
            #expect(feedbackClaims?["v"] as? Int == 1)
            #expect(feedbackClaims?["typ"] as? String == "scope-attestation")
            #expect(UUID(uuidString: feedbackClaims?["nonce"] as? String ?? "") != nil)
            #expect(feedbackClaims?["scope"] as? String == "feedback-report:create")
            #expect(feedbackClaims?["actorType"] as? String == "user")
            #expect(feedbackClaims?["sub"] as? String == ownerId)
            #expect(feedbackClaims?["serverId"] as? String == serverId)
            #expect(feedbackClaims?["aud"] as? String == "feedback-worker")
            #expect(feedbackClaims?["resource"] as? String == "servers/\(serverId)/feedback-reports")
        }
    }
    accounts.setScopeAttestationSecretForTesting(nil)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var fields = HTTPFields()
            fields[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
            fields[.contentType] = "application/json"
            fields[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.post, headers: fields, to: URI(string: "/api/servers/\(serverId)/scope-attestation")) { request in
                request.body = .init(string: "{\"scope\":\"web-trace-batch:create\"}")
            }
            #expect(response.status == .serviceUnavailable)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            #expect((body?["error"] as? String)?.contains("not configured") == true)
            #expect(body?["attestation"] == nil)
        }
    }
}


private enum AttestationClaims {
    static let secret = "user-scope-test-only-é-🔐-independent-key"

    static func verifiedScopeClaims(_ token: String, secret: String = AttestationClaims.secret) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts.contains(where: { $0.isEmpty || $0.contains("=") }) else { return nil }
        func decode(_ value: Substring) -> Data? {
            var encoded = String(value).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while encoded.count % 4 != 0 { encoded += "=" }
            return Data(base64Encoded: encoded)
        }
        guard let signature = decode(parts[1]),
              HMAC<SHA256>.isValidAuthenticationCode(
                  signature, authenticating: Data(parts[0].utf8), using: SymmetricKey(data: Data(secret.utf8))
              ), let data = decode(parts[0]) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
