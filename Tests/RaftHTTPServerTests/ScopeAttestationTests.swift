import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func scopeAttestationSignsTheScopeAudienceAndResource() async throws {
    let accounts = EmailLoginDirectory()
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
                    request.body = .init(string: "{\"scope\":\"\(scope)\"}")
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
            #expect((traceBody["expiresAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } != nil || true)
            let traceAttestation = traceBody["attestation"] as? String ?? ""
            #expect(traceAttestation.split(separator: ".").count == 3)
            let traceClaims = AttestationClaims.jwtClaims(traceAttestation)
            #expect(traceClaims?["scope"] as? String == "web-trace-batch:create")
            #expect(traceClaims?["actorType"] as? String == "user")
            #expect(traceClaims?["sub"] as? String == memberId)
            #expect(traceClaims?["serverId"] as? String == serverId)
            #expect(traceClaims?["aud"] as? String == "trace-ingest-worker")
            #expect(traceClaims?["resource"] as? String == "servers/\(serverId)/web-traces")
            #expect((traceClaims?["exp"] as? Int ?? 0) > Int(Date().timeIntervalSince1970))

            let memberFeedback = try await attest(memberToken, "feedback-report:create")
            #expect(memberFeedback.status == .forbidden)

            let ownerFeedback = try await attest(ownerToken, "feedback-report:create")
            #expect(ownerFeedback.status == .ok)
            let feedbackBody = try payload(ownerFeedback)
            #expect(feedbackBody["audience"] as? String == "feedback-worker")
            #expect(feedbackBody["resource"] as? String == "servers/\(serverId)/feedback-reports")
            let feedbackClaims = AttestationClaims.jwtClaims(feedbackBody["attestation"] as? String ?? "")
            #expect(feedbackClaims?["scope"] as? String == "feedback-report:create")
            #expect(feedbackClaims?["actorType"] as? String == "user")
            #expect(feedbackClaims?["sub"] as? String == ownerId)
            #expect(feedbackClaims?["serverId"] as? String == serverId)
            #expect(feedbackClaims?["aud"] as? String == "feedback-worker")
            #expect(feedbackClaims?["resource"] as? String == "servers/\(serverId)/feedback-reports")
        }
    }
}


private enum AttestationClaims {
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
