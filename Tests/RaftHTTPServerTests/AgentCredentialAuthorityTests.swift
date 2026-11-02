import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct CredentialAuthorityFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let memberId: String
    let memberEmail: String
    let outsiderEmail: String
    let ownerAgent: String
    let memberAgent: String
}

private func makeCredentialAuthorityFixture() -> CredentialAuthorityFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000980001"
    let ownerId = "11111111-1111-4111-8111-000000980001"
    let memberId = "11111111-1111-4111-8111-000000980002"
    let outsiderId = "11111111-1111-4111-8111-000000980003"
    let ownerEmail = "cred-owner@slock.test"
    let memberEmail = "cred-member@slock.test"
    let outsiderEmail = "cred-outsider@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail), (outsiderId, outsiderEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "cred", name: "Cred", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let ownerAgent = accounts.oauth.createAgent(
        serverId: serverId,
        name: "cred-owner-agent",
        creatorUserId: ownerId,
        runtime: "external"
    )
    let memberAgent = accounts.oauth.createAgent(
        serverId: serverId,
        name: "cred-member-agent",
        creatorUserId: memberId,
        runtime: "external"
    )
    return CredentialAuthorityFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        memberId: memberId,
        memberEmail: memberEmail,
        outsiderEmail: outsiderEmail,
        ownerAgent: ownerAgent,
        memberAgent: memberAgent
    )
}

private func credentialLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func credentialHeaders(_ token: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    return headers
}

private func credentialObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func ownerMintsAgentCredentialsWithoutTheServerHeader() async throws {
    let fixture = makeCredentialAuthorityFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await credentialLogin(client, email: fixture.ownerEmail)
            let mint = try await client.send(.post, headers: credentialHeaders(owner), to: URI(string: "/api/agents/\(fixture.ownerAgent)/credentials")) { request in
                request.body = .init(string: "{}")
            }
            #expect(mint.status.code == 201)
            #expect(mint.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let minted = try credentialObject(mint)
            let apiKey = try #require(minted["apiKey"] as? String)
            let credentialId = try #require(minted["credentialId"] as? String)
            #expect(apiKey.hasPrefix("sk_agent_"))
            #expect(minted["agentId"] as? String == fixture.ownerAgent)
            #expect(minted["serverId"] as? String == fixture.serverId)

            var whoHeaders = HTTPFields()
            whoHeaders[.authorization] = "Bearer \(apiKey)"
            let who = try await client.get("/internal/agent-api/", headers: whoHeaders)
            #expect(who.status == .ok)
            let identity = try credentialObject(who)
            #expect(identity["agentId"] as? String == fixture.ownerAgent)
            #expect(identity["credentialId"] as? String == credentialId)

            let list = try await client.get(URI(string: "/api/agents/\(fixture.ownerAgent)/credentials"), headers: credentialHeaders(owner))
            #expect(list.status == .ok)
            #expect(list.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let credentials = try credentialObject(list)["credentials"] as? [[String: Any]] ?? []
            #expect(credentials.count == 1)
            #expect(credentials[0]["maskedToken"] as? String == String(apiKey.prefix(14)) + "***")
            #expect(Set(credentials[0].keys) == Set(["id", "maskedToken", "name", "scopes", "createdAt", "lastUsedAt", "revokedAt"]))

            let revoke = try await client.send(.delete, headers: credentialHeaders(owner), to: URI(string: "/api/agents/\(fixture.ownerAgent)/credentials/\(credentialId)"))
            #expect(revoke.status.code == 204)
            let again = try await client.send(.delete, headers: credentialHeaders(owner), to: URI(string: "/api/agents/\(fixture.ownerAgent)/credentials/\(credentialId)"))
            #expect(again.status.code == 204)
            #expect(try await client.get("/internal/agent-api/", headers: whoHeaders).status == .unauthorized)
        }
    }
}

@Test func agentCreatorKeepsCredentialAuthorityAndOtherMembersDoNot() async throws {
    let fixture = makeCredentialAuthorityFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let member = try await credentialLogin(client, email: fixture.memberEmail)
            let mint = try await client.send(.post, headers: credentialHeaders(member), to: URI(string: "/api/agents/\(fixture.memberAgent)/credentials")) { request in
                request.body = .init(string: "{}")
            }
            #expect(mint.status.code == 201)
            let credentialId = try #require(try credentialObject(mint)["credentialId"] as? String)
            #expect(try await client.get(URI(string: "/api/agents/\(fixture.memberAgent)/credentials"), headers: credentialHeaders(member)).status == .ok)
            #expect(try await client.send(.delete, headers: credentialHeaders(member), to: URI(string: "/api/agents/\(fixture.memberAgent)/credentials/\(credentialId)")).status.code == 204)

            let denied = try await client.send(.post, headers: credentialHeaders(member), to: URI(string: "/api/agents/\(fixture.ownerAgent)/credentials")) { request in
                request.body = .init(string: "{}")
            }
            #expect(denied.status == .forbidden)
            #expect(try credentialObject(denied)["code"] as? String == "insufficient_role")
            #expect(try await client.get(URI(string: "/api/agents/\(fixture.ownerAgent)/credentials"), headers: credentialHeaders(member)).status == .forbidden)
            #expect(try await client.send(.delete, headers: credentialHeaders(member), to: URI(string: "/api/agents/\(fixture.ownerAgent)/credentials/\(credentialId)")).status == .forbidden)

            let outsider = try await credentialLogin(client, email: fixture.outsiderEmail)
            let missing = try await client.get(URI(string: "/api/agents/\(fixture.ownerAgent)/credentials"), headers: credentialHeaders(outsider))
            #expect(missing.status == .notFound)
            #expect(try credentialObject(missing)["code"] as? String == "agent_missing")
        }
    }
}

@Test func deletedAndUnknownAgentsShareTheAgentMissingShape() async throws {
    let fixture = makeCredentialAuthorityFixture()
    let unknown = "99999999-9999-4999-8999-999999999999"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await credentialLogin(client, email: fixture.ownerEmail)
            let unknownResponse = try await client.get(URI(string: "/api/agents/\(unknown)/credentials"), headers: credentialHeaders(owner))
            #expect(unknownResponse.status == .notFound)
            #expect(try credentialObject(unknownResponse) as NSDictionary == ["code": "agent_missing", "error": "Agent not found"] as NSDictionary)

            fixture.accounts.oauth.deleteAgent(id: fixture.ownerAgent)
            let deleted = try await client.get(URI(string: "/api/agents/\(fixture.ownerAgent)/credentials"), headers: credentialHeaders(owner))
            #expect(deleted.status == .notFound)
            #expect(try credentialObject(deleted)["code"] as? String == "agent_missing")
            let denied = try await client.post(URI(string: "/api/agents/\(fixture.ownerAgent)/credentials"), headers: credentialHeaders(owner)) { request in
                request.body = .init(string: "{}")
            }
            #expect(denied.status == .notFound)
            #expect(try credentialObject(denied)["code"] as? String == "agent_missing")
        }
    }
}
