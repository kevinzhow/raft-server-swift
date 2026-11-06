import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct AgentGrantFixture {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let serverId: String
    let agentId: String
    let joinChannelId: String
    let taskChannelName: String
    let taskChannelId: String
    let agentKey: String
    let machineKey: String
}

private func makeAgentGrantFixture(suffix: String) -> AgentGrantFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 900_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 111_000 + number)
    accounts.addAccount(id: ownerId, email: "agent-api-grants-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-api-grants-\(suffix)", name: "Agent API Grants", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "AgentApiGrantsBot-\(suffix)", runtime: "claude")

    let taskChannelName = "grants-tasks-\(suffix)"
    let taskChannel = accounts.oauth.createChannel(serverId: serverId, name: taskChannelName, creatorUserId: ownerId)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: taskChannel, memberId: member, name: taskChannelName)
    }
    accounts.oauth.addChannelHuman(channelId: taskChannel, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: taskChannel, agentId: agent)

    let joinChannel = accounts.oauth.createChannel(serverId: serverId, name: "grants-join-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: joinChannel, memberId: ownerId, name: "grants-join-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: joinChannel, userId: ownerId)

    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "agent-api-grants-machine-\(suffix)")
    let machineKey = accounts.machineAPIKey(machineId: machine) ?? ""
    let agentKey = accounts.mintAgentCredential(agentId: agent, scopes: ["channels", "tasks"], name: "grants-test-\(suffix)")
    return AgentGrantFixture(
        accounts: accounts,
        ownerId: ownerId,
        serverId: serverId,
        agentId: agent,
        joinChannelId: joinChannel,
        taskChannelName: taskChannelName,
        taskChannelId: taskChannel,
        agentKey: agentKey,
        machineKey: machineKey
    )
}

private let everyGrantable = [
    "channel:join", "task:read", "task:write", "message:read", "message:send",
]

private func agentGrantPost(_ client: any Client, key: String, path: String, body: String = "{}") async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func agentGrantObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func defaultAgentGrantsKeepJoinAndTaskCreateWorking() async throws {
    let fixture = makeAgentGrantFixture(suffix: "771")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let join = try await agentGrantPost(
                client,
                key: fixture.agentKey,
                path: "/internal/agent-api/channels/\(fixture.joinChannelId)/join"
            )
            #expect(join.status == .ok)
            #expect(fixture.accounts.oauth.channelAgentIds(channelId: fixture.joinChannelId).contains(fixture.agentId))

            let create = try await agentGrantPost(
                client,
                key: fixture.agentKey,
                path: "/internal/agent-api/tasks",
                body: "{\"channel\":\"#\(fixture.taskChannelName)\",\"tasks\":[{\"title\":\"default grants task\"}]}"
            )
            #expect(create.status == .ok)
            let listed = try await client.get(
                URI(string: "/internal/agent-api/tasks?channel=\(("#\(fixture.taskChannelName)").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"),
                headers: {
                    var headers = HTTPFields()
                    headers[.authorization] = "Bearer \(fixture.agentKey)"
                    return headers
                }()
            )
            #expect(listed.status == .ok)
            #expect(try agentGrantObject(listed)["tasks"] as? [[String: Any]] != nil)
        }
    }
}

@Test func customGrantsWithoutChannelJoinDenyBothAPIsAndWriteNothing() async throws {
    let fixture = makeAgentGrantFixture(suffix: "772")
    fixture.accounts.setAgentGrantsForTesting(
        agentId: fixture.agentId,
        scopes: everyGrantable.filter { $0 != "channel:join" }
    )
    let expected: NSDictionary = [
        "error": "missing required scope",
        "requiredScope": "channel:join",
        "reason": "missing_scope",
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let denied = try await agentGrantPost(
                client,
                key: fixture.agentKey,
                path: "/internal/agent-api/channels/\(fixture.joinChannelId)/join"
            )
            #expect(denied.status == .forbidden)
            #expect(try agentGrantObject(denied) as NSDictionary == expected)
            #expect(!fixture.accounts.oauth.channelAgentIds(channelId: fixture.joinChannelId).contains(fixture.agentId))

            let legacyDenied = try await agentGrantPost(
                client,
                key: fixture.machineKey,
                path: "/internal/agent/\(fixture.agentId)/channels/\(fixture.joinChannelId)/join"
            )
            #expect(legacyDenied.status == .forbidden)
            #expect(try agentGrantObject(legacyDenied) as NSDictionary == expected)
            #expect(!fixture.accounts.oauth.channelAgentIds(channelId: fixture.joinChannelId).contains(fixture.agentId))

            let create = try await agentGrantPost(
                client,
                key: fixture.agentKey,
                path: "/internal/agent-api/tasks",
                body: "{\"channel\":\"#\(fixture.taskChannelName)\",\"tasks\":[{\"title\":\"task while join revoked\"}]}"
            )
            #expect(create.status == .ok)

            fixture.accounts.resetAgentGrantsForTesting(agentId: fixture.agentId)
            let allowed = try await agentGrantPost(
                client,
                key: fixture.agentKey,
                path: "/internal/agent-api/channels/\(fixture.joinChannelId)/join"
            )
            #expect(allowed.status == .ok)
            #expect(fixture.accounts.oauth.channelAgentIds(channelId: fixture.joinChannelId).contains(fixture.agentId))
        }
    }
}

@Test func customGrantsWithoutTaskWriteDenyBothAPIsAndWriteNothing() async throws {
    let fixture = makeAgentGrantFixture(suffix: "773")
    fixture.accounts.setAgentGrantsForTesting(
        agentId: fixture.agentId,
        scopes: everyGrantable.filter { $0 != "task:write" }
    )
    let expected: NSDictionary = [
        "error": "missing required scope",
        "requiredScope": "task:write",
        "reason": "missing_scope",
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let body = "{\"channel\":\"#\(fixture.taskChannelName)\",\"tasks\":[{\"title\":\"should not exist\"}]}"
            let denied = try await agentGrantPost(
                client,
                key: fixture.agentKey,
                path: "/internal/agent-api/tasks",
                body: body
            )
            #expect(denied.status == .forbidden)
            #expect(try agentGrantObject(denied) as NSDictionary == expected)

            let legacyDenied = try await agentGrantPost(
                client,
                key: fixture.machineKey,
                path: "/internal/agent/\(fixture.agentId)/tasks",
                body: body
            )
            #expect(legacyDenied.status == .forbidden)
            #expect(try agentGrantObject(legacyDenied) as NSDictionary == expected)

            var listHeaders = HTTPFields()
            listHeaders[.authorization] = "Bearer \(fixture.agentKey)"
            let list = try await client.get(
                URI(string: "/internal/agent-api/tasks?channel=\(("#\(fixture.taskChannelName)").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"),
                headers: listHeaders
            )
            #expect(list.status == .ok)
            #expect((try agentGrantObject(list)["tasks"] as? [[String: Any]] ?? []).isEmpty)

            fixture.accounts.resetAgentGrantsForTesting(agentId: fixture.agentId)
            let allowed = try await agentGrantPost(
                client,
                key: fixture.agentKey,
                path: "/internal/agent-api/tasks",
                body: "{\"channel\":\"#\(fixture.taskChannelName)\",\"tasks\":[{\"title\":\"after reset\"}]}"
            )
            #expect(allowed.status == .ok)
            let after = try await client.get(
                URI(string: "/internal/agent-api/tasks?channel=\(("#\(fixture.taskChannelName)").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"),
                headers: listHeaders
            )
            #expect((try agentGrantObject(after)["tasks"] as? [[String: Any]] ?? []).count == 1)
        }
    }
}
