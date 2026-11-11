import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The pinned `resolveSearchSenderFilter` resolves `sender=@handle` through
/// `resolveUserByName` / `resolveAgentByName`: canonical handles only
/// (`users.name` / `agents.name`), exact and case-sensitive, with humans
/// restricted to members of the requester's server. Display names and
/// case-folded handles must not widen the query.
private struct SearchSenderFixture {
    let accounts: EmailLoginDirectory
    let serverId = "33333333-3333-4333-8333-000001320001"
    let ownerId = "11111111-1111-4111-8111-000001320001"
    let aliceId = "11111111-1111-4111-8111-000001320002"
    let bobId = "11111111-1111-4111-8111-000001320003"
    let outsiderId = "11111111-1111-4111-8111-000001320004"
    var graceId = ""
    var agentKey = ""
    var machineKey = ""
    var channelId = ""
    var aliceMessage = ""
    var bobMessage = ""
}

private func makeSearchSenderFixture() -> SearchSenderFixture {
    var f = SearchSenderFixture(accounts: EmailLoginDirectory())
    let accounts = f.accounts
    for (id, email) in [
        (f.ownerId, "search-sender-owner"),
        (f.aliceId, "search-sender-alice"),
        (f.bobId, "search-sender-bob"),
        (f.outsiderId, "search-sender-outsider"),
    ] {
        accounts.addAccount(id: id, email: "\(email)@slock.test", password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: f.serverId, slug: "search-sender", name: "Search Sender", ownerId: f.ownerId)
    accounts.setAccountProfileForTesting(id: f.aliceId, name: "alice", displayName: "bob")
    accounts.setAccountProfileForTesting(id: f.bobId, name: "bob", displayName: "Bobby")
    accounts.oauth.addMember(serverId: f.serverId, userId: f.aliceId, role: "member")
    accounts.oauth.addMember(serverId: f.serverId, userId: f.bobId, role: "member")
    // The outsider is a live account on a different server; the harness still
    // shares one account directory, so only the membership rule can hide them.
    let outsiderServer = "33333333-3333-4333-8333-000001320099"
    accounts.oauth.addOwnedServer(id: outsiderServer, slug: "search-sender-other", name: "Other Server", ownerId: f.outsiderId)
    let grace = accounts.oauth.createAgent(serverId: f.serverId, name: "Searcher", runtime: "claude")
    f.graceId = grace
    f.agentKey = accounts.mintAgentCredential(agentId: grace, scopes: ["send", "read"], name: "search-sender")
    f.machineKey = accounts.registerMachineForAgent(serverId: f.serverId, agentId: grace)
    let channelId = accounts.oauth.createChannel(serverId: f.serverId, name: "search-sender-room", creatorUserId: f.ownerId)
    accounts.seedPostableChannelForTesting(
        serverId: f.serverId, channelId: channelId, name: "search-sender-room",
        humanIds: [f.ownerId, f.aliceId, f.bobId], agentIds: [grace]
    )
    f.channelId = channelId
    f.aliceMessage = accounts.addHumanMessageForTesting(channelId: channelId, senderId: f.aliceId, content: "parityneedle from alice")
    f.bobMessage = accounts.addHumanMessageForTesting(channelId: channelId, senderId: f.bobId, content: "parityneedle from bob")
    return f
}

private func agentApiSearch(
    _ client: any Client, apiKey: String, query: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let response = try await client.get(URI(string: "/internal/agent-api/search?\(query)"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private func machineSearch(
    _ client: any Client, agentId: String, machineKey: String, query: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(machineKey)"
    let response = try await client.get(URI(string: "/internal/agent/\(agentId)/search?\(query)"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private func resultIds(_ body: [String: Any]) -> [String] {
    (body["results"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
}

@Test func searchSenderResolvesOnlyTheCanonicalHandle() async throws {
    let f = makeSearchSenderFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let bob = try await agentApiSearch(client, apiKey: f.agentKey, query: "q=parityneedle&sender=@bob&sort=recent")
            #expect(bob.status == .ok)
            #expect(resultIds(bob.body) == [f.bobMessage])

            let alice = try await agentApiSearch(client, apiKey: f.agentKey, query: "q=parityneedle&sender=@alice&sort=recent")
            #expect(alice.status == .ok)
            #expect(resultIds(alice.body) == [f.aliceMessage])

            // Display names and case variants are not handles.
            for query in ["q=parityneedle&sender=@Bobby", "q=parityneedle&sender=@Alice", "q=parityneedle&sender=bobby"] {
                let refused = try await agentApiSearch(client, apiKey: f.agentKey, query: query)
                #expect(refused.status == .notFound, "\(query) must not resolve a sender")
                #expect(refused.body["errorCode"] as? String == "member_not_found")
                #expect(resultIds(refused.body).isEmpty)
            }

            // A human on another server is not a member here.
            let outsider = try await agentApiSearch(client, apiKey: f.agentKey, query: "q=parityneedle&sender=@search-sender-outsider")
            #expect(outsider.status == .notFound)
            #expect(outsider.body["errorCode"] as? String == "member_not_found")

            // The machine-keyed route applies the same canonical rules.
            let machineBob = try await machineSearch(
                client, agentId: f.graceId, machineKey: f.machineKey, query: "q=parityneedle&sender=@bob&sort=recent"
            )
            #expect(machineBob.status == .ok)
            #expect(resultIds(machineBob.body) == [f.bobMessage])
            let machineDisplayName = try await machineSearch(
                client, agentId: f.graceId, machineKey: f.machineKey, query: "q=parityneedle&sender=@Bobby"
            )
            #expect(machineDisplayName.status == .notFound)
            #expect(machineDisplayName.body["errorCode"] as? String == "member_not_found")
            let machineCaseVariant = try await machineSearch(
                client, agentId: f.graceId, machineKey: f.machineKey, query: "q=parityneedle&sender=@Alice"
            )
            #expect(machineCaseVariant.status == .notFound)
        }
    }
}

@Test func searchSenderKeepsTheHumanAgentTwinConflict() async throws {
    let f = makeSearchSenderFixture()
    // A live agent with the same canonical handle as the human bob.
    _ = f.accounts.oauth.createAgent(serverId: f.serverId, name: "bob", runtime: "claude")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let twin = try await agentApiSearch(client, apiKey: f.agentKey, query: "q=parityneedle&sender=@bob")
            #expect(twin.status == .conflict)
            #expect(twin.body["errorCode"] as? String == "ambiguous_member_ref")
        }
    }
}
