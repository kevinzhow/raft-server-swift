import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private let scopeLimit = 1024 * 1024

private struct ScopeLimitFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001094001"
    let ownerId = "11111111-1111-4111-8111-000001094001"
    var apiKey: String = ""

    init() {
        accounts.addAccount(id: ownerId, email: "scope-body-owner@scope.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "scope-body", name: "Scope Body", ownerId: ownerId)
    }

    mutating func registerMachine() {
        let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "scope-body-machine")
        apiKey = accounts.machineAPIKey(machineId: machineId) ?? ""
    }
}

private func bodyOfExactly(_ bytes: Int) -> String {
    let json = "{\"scope\":\"daemon-trace-bundle:create\",\"metadata\":{\"bundleId\":\"bundle-limit\",\"bundleSha256\":\"\(String(repeating: "c", count: 64))\",\"bundleSizeBytes\":1024}}"
    let pad = bytes - json.utf8.count
    precondition(pad >= 0)
    return json + String(repeating: " ", count: pad)
}

private func post(_ client: any Client, _ path: String, _ body: String, apiKey: String?) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let apiKey { headers[.authorization] = "Bearer \(apiKey)" }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

@Test func scopeAttestationBodyLimitAcceptsOneMiBAndRejectsOneMore() async throws {
    var fixture = ScopeLimitFixture()
    fixture.registerMachine()
    fixture.accounts.setScopeAttestationSecretForTesting("scope-body-secret")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let legacySized = try await post(client, "/internal/machine/scope-attestation", bodyOfExactly(180 * 1024), apiKey: fixture.apiKey)
            #expect(legacySized.status == .ok)
            let atLimit = try await post(client, "/internal/machine/scope-attestation", bodyOfExactly(scopeLimit), apiKey: fixture.apiKey)
            #expect(atLimit.status == .ok)
            let over = try await post(client, "/internal/machine/scope-attestation", bodyOfExactly(scopeLimit + 1), apiKey: fixture.apiKey)
            #expect(over.status == .contentTooLarge)
            #expect((over.headers[.contentType] ?? "").contains("application/json"))
            let body = (try? JSONSerialization.jsonObject(with: Data((over.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(body["code"] as? String == "scope_attestation_body_too_large")
            #expect(body["limitBytes"] as? Int == scopeLimit)
        }
    }
}

@Test func otherRoutesKeepGlobalLimitAndMachineAuthRunsFirst() async throws {
    var fixture = ScopeLimitFixture()
    fixture.registerMachine()
    fixture.accounts.setScopeAttestationSecretForTesting("scope-body-secret")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            let big = bodyOfExactly(180 * 1024)
            for path in ["/internal/machine/agents/00000000-0000-4000-8000-000000000000/stop", "/internal/machine/scope-attestation-other", "/api/auth/login"] {
                let response = try await post(client, path, big, apiKey: fixture.apiKey)
                #expect(response.status == .contentTooLarge, Comment(rawValue: path))
            }
            for bytes in [180 * 1024, scopeLimit + 1] {
                let unauthenticated = try await post(client, "/internal/machine/scope-attestation", bodyOfExactly(bytes), apiKey: nil)
                #expect(unauthenticated.status == .unauthorized)
                let bad = try await post(client, "/internal/machine/scope-attestation", bodyOfExactly(bytes), apiKey: "sk_machine_not_a_real_key")
                #expect(bad.status == .unauthorized)
            }
            var statuses = Set<Int>()
            for _ in 0..<150 {
                let response = try await post(client, "/internal/machine/scope-attestation", bodyOfExactly(512), apiKey: fixture.apiKey)
                statuses.insert(Int(response.status.code))
            }
            #expect(statuses == [200])
        }
    }
}
