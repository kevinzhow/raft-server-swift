import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ProviderGateFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let otherServerId: String
    let ownerId: String
    let ownerToken: String
    let memberToken: String
}

private func makeProviderGateFixture(_ suffix: String) -> ProviderGateFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001270\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001271\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001270\(suffix)"
    let otherServerId = "33333333-3333-4333-8333-000001271\(suffix)"
    accounts.addAccount(id: ownerId, email: "provider-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "provider-member-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "provider-gate-a-\(suffix)", name: "Provider Gate A \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "provider-gate-b-\(suffix)", name: "Provider Gate B \(suffix)", ownerId: ownerId)
    return ProviderGateFixture(
        accounts: accounts,
        serverId: serverId,
        otherServerId: otherServerId,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId)
    )
}

private func providerHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func providerProbe(
    _ client: any Client,
    f: ProviderGateFixture,
    token: String,
    serverId: String? = nil,
    kind: String = "antiproton"
) async throws -> (status: HTTPResponse.Status, body: [String: Any], raw: String) {
    let response = try await client.get(
        URI(string: "/api/agent-runtime-providers/\(kind)"),
        headers: providerHeaders(token, serverId ?? f.serverId)
    )
    let raw = response.body.string ?? ""
    let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    return (response.status, json, raw)
}

private func providerCreate(
    _ client: any Client,
    f: ProviderGateFixture,
    body: String,
    serverId: String? = nil
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    let response = try await client.send(.post, headers: providerHeaders(f.ownerToken, serverId ?? f.serverId), to: "/api/agents") { request in
        request.body = .init(string: body)
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@Test func runtimeProviderProbeIsAuthorityGatedAndLeaksNoConfiguration() async throws {
    let f = makeProviderGateFixture("901")
    f.accounts.setHostedProviderTokenForTesting("pt-fake-provider-token-0123456789abcdef")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let memberProbe = try await providerProbe(client, f: f, token: f.memberToken)
            #expect(memberProbe.status == .forbidden)
            #expect(!memberProbe.raw.contains("pt-fake-provider-token"))

            let unknown = try await providerProbe(client, f: f, token: f.ownerToken, kind: "nope")
            #expect(unknown.status == .notFound)

            for method in [HTTPRequest.Method.put, .delete] {
                let gone = try await client.send(method, headers: providerHeaders(f.ownerToken, f.serverId), to: "/api/agent-runtime-providers/antiproton") { request in
                    request.body = .init(string: "{\"baseUrl\":\"http://127.0.0.1:1\",\"token\":\"pt-fake-provider-token-0123456789abcdef\"}")
                }
                #expect(gone.status == .notFound, "the config route stays gone")
            }

            let probe = try await providerProbe(client, f: f, token: f.ownerToken)
            #expect(probe.status == .ok)
            #expect(probe.body["kind"] as? String == "antiproton")
            #expect(!probe.raw.contains("pt-fake-provider-token"))
            #expect(!probe.raw.contains("127.0.0.1"))
        }
    }
}

@Test func hostedProviderNeedsBothTheDeploymentConfigAndTheServerFlag() async throws {
    let f = makeProviderGateFixture("902")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            // Flag off, no token: unavailable and creation refused by the flag.
            #expect(try await providerProbe(client, f: f, token: f.ownerToken).body["available"] as? Bool == false)
            let flagOff = try await providerCreate(client, f: f, body: "{\"name\":\"gate-off\",\"external\":true,\"provider\":\"antiproton\"}")
            #expect(flagOff.status == .forbidden)
            #expect(flagOff.body["code"] as? String == "agent_runtime_provider_disabled")

            // Token configured, flag still off: still unavailable.
            f.accounts.setHostedProviderTokenForTesting("pt-fake-provider-token-0123456789abcdef")
            #expect(try await providerProbe(client, f: f, token: f.ownerToken).body["available"] as? Bool == false)
            let tokenOnly = try await providerCreate(client, f: f, body: "{\"name\":\"gate-flag-off\",\"external\":true,\"provider\":\"antiproton\"}")
            #expect(tokenOnly.status == .forbidden)

            // Flag on, token unset: unavailable with a configuration error.
            f.accounts.setHostedProviderTokenForTesting(nil)
            f.accounts.enableHostedRuntimeForTesting(serverId: f.serverId)
            #expect(try await providerProbe(client, f: f, token: f.ownerToken).body["available"] as? Bool == false)
            let unconfigured = try await providerCreate(client, f: f, body: "{\"name\":\"gate-no-token\",\"external\":true,\"provider\":\"antiproton\"}")
            #expect(unconfigured.status == .conflict)
            #expect(unconfigured.body["code"] as? String == "agent_runtime_provider_not_configured")

            // Both: available for this server and creation starts provisioning.
            f.accounts.setHostedProviderTokenForTesting("pt-fake-provider-token-0123456789abcdef")
            #expect(try await providerProbe(client, f: f, token: f.ownerToken).body["available"] as? Bool == true)
            let created = try await providerCreate(client, f: f, body: "{\"name\":\"gate-on\",\"external\":true,\"provider\":\"antiproton\"}")
            #expect(created.status == .ok)
            let hosted = try #require(created.body["hostedRuntime"] as? [String: Any])
            #expect(hosted["state"] as? String == "provisioning")

            // A managed agent cannot select the hosted provider.
            let managed = try await providerCreate(client, f: f, body: "{\"name\":\"managed-hosted\",\"provider\":\"antiproton\"}")
            #expect(managed.status == .badRequest)

            // The other server never sees the availability even with the token.
            let otherProbe = try await providerProbe(client, f: f, token: f.ownerToken, serverId: f.otherServerId)
            #expect(otherProbe.body["available"] as? Bool == false)
            let otherCreate = try await providerCreate(client, f: f, body: "{\"name\":\"gate-b\",\"external\":true,\"provider\":\"antiproton\"}", serverId: f.otherServerId)
            #expect(otherCreate.status == .forbidden)
            #expect(otherCreate.body["code"] as? String == "agent_runtime_provider_disabled")
        }
    }
}
