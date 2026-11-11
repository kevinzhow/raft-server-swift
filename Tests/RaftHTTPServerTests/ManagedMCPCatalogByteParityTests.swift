import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

// Byte-exact locks for the managed MCP control plane, the reminder routes, the
// saved-message write and the agent history read. Each expected string is the
// legacy body, member order included.

private struct CatalogFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let memberId: String
    let agentId: String
    let ownerToken: String
    let memberToken: String
}

private func makeCatalogFixture(_ suffix: String) -> CatalogFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001300\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001310\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001300\(suffix)"
    for (id, email) in [(ownerId, "catalog-owner-\(suffix)@slock.test"), (memberId, "catalog-member-\(suffix)@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "catalog-\(suffix)", name: "Catalog \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "catalog-agent-\(suffix)", creatorUserId: ownerId, runtime: "claude")
    return CatalogFixture(
        accounts: accounts, serverId: serverId, ownerId: ownerId, memberId: memberId, agentId: agentId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId)
    )
}

private func bearer(_ token: String, serverId: String? = nil) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return headers
}

private func text(_ response: ClientResponse) -> String { response.body.string ?? "" }

private func redactingTimestamps(_ body: String) -> String {
    body.replacingOccurrences(
        of: #""(createdAt|fireAt)":"[^"]*""#, with: "\"$1\":\"T\"", options: .regularExpression
    )
}

private func jsonField(_ body: String, _ key: String) -> String {
    let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    return object?[key] as? String ?? ""
}

@Test func managedMCPControlPlaneBodiesKeepTheLegacyMemberOrder() async throws {
    let fixture = makeCatalogFixture("01")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = bearer(fixture.ownerToken, serverId: fixture.serverId)
            let member = bearer(fixture.memberToken, serverId: fixture.serverId)

            let empty = try await client.get("/api/mcp/servers", headers: owner)
            #expect(empty.status == .ok)
            #expect(text(empty) == "{\"servers\":[],\"recommendations\":[{\"id\":\"notion\"},{\"id\":\"linear\"}]}")
            #expect(empty.headers[.contentType] == "application/json; charset=utf-8")

            let denied = try await client.send(.post, headers: member, to: "/api/mcp/servers") { $0.body = .init(string: "{}") }
            #expect(denied.status == .forbidden)
            #expect(text(denied) == "{\"error\":\"Only server owners and admins can manage MCP servers\"}")
            let missing = try await client.send(.post, headers: owner, to: "/api/mcp/servers") { $0.body = .init(string: "{\"name\":\"x\"}") }
            #expect(missing.status == .badRequest)
            #expect(text(missing) == "{\"error\":\"name and endpointUrl are required\",\"code\":\"managed_mcp_request_invalid\"}")
            let notObject = try await client.send(.post, headers: owner, to: "/api/mcp/servers") { $0.body = .init(string: "[1]") }
            #expect(text(notObject) == "{\"error\":\"name and endpointUrl are required\",\"code\":\"managed_mcp_request_invalid\"}")
            let badEndpoint = try await client.send(.post, headers: owner, to: "/api/mcp/servers") {
                $0.body = .init(string: "{\"name\":\"x\",\"endpointUrl\":\"http://example.com/mcp\"}")
            }
            #expect(badEndpoint.status == .badRequest)
            #expect(text(badEndpoint) == "{\"error\":\"Endpoint must be a public HTTPS URL without credentials, query, or fragment\",\"code\":\"managed_mcp_endpoint_invalid\"}")
            let wrongProvider = try await client.send(.post, headers: owner, to: "/api/mcp/servers") {
                $0.body = .init(string: "{\"name\":\"x\",\"provider\":\"notion\",\"authMode\":\"oauth\",\"endpointUrl\":\"https://example.com/mcp\"}")
            }
            #expect(wrongProvider.status == .conflict)
            #expect(text(wrongProvider) == "{\"error\":\"That provider must use its managed endpoint\",\"code\":\"managed_mcp_auth_invalid\"}")
            let badHeader = try await client.send(.post, headers: owner, to: "/api/mcp/servers") {
                $0.body = .init(string: "{\"name\":\"x\",\"endpointUrl\":\"https://example.com/mcp\",\"headers\":{\"A\":1}}")
            }
            #expect(text(badHeader) == "{\"error\":\"Header values must be strings\",\"code\":\"managed_mcp_request_invalid\"}")

            let notion = try await client.send(.post, headers: owner, to: "/api/mcp/servers") {
                $0.body = .init(string: "{\"name\":\" Notion \",\"provider\":\"notion\",\"authMode\":\"oauth\",\"endpointUrl\":\"https://mcp.notion.com/mcp\"}")
            }
            #expect(notion.status == .created)
            let notionId = jsonField(text(notion), "id")
            #expect(text(notion) == "{\"id\":\"\(notionId)\",\"name\":\"Notion\",\"provider\":\"notion\",\"authMode\":\"oauth\",\"oauthStatus\":\"disconnected\",\"endpointUrl\":\"https://mcp.notion.com/mcp\",\"hasCredentials\":false,\"credentialHeaderNames\":[],\"assignment\":null}")

            let keyed = try await client.send(.post, headers: owner, to: "/api/mcp/servers") {
                $0.body = .init(string: "{\"name\":\"Keyed\",\"endpointUrl\":\"https://example.com/mcp\",\"headers\":{\"X-Api-Key\":\"secret\"}}")
            }
            let keyedId = jsonField(text(keyed), "id")
            #expect(text(keyed) == "{\"id\":\"\(keyedId)\",\"name\":\"Keyed\",\"provider\":null,\"authMode\":null,\"oauthStatus\":null,\"endpointUrl\":\"https://example.com/mcp\",\"hasCredentials\":true,\"credentialHeaderNames\":[\"X-Api-Key\"],\"assignment\":null}")

            // A refused endpoint keeps the name the same patch already wrote.
            let partial = try await client.send(.patch, headers: owner, to: URI(string: "/api/mcp/servers/\(keyedId)")) {
                $0.body = .init(string: "{\"name\":\"Renamed\",\"endpointUrl\":\"http://nope.example\"}")
            }
            #expect(partial.status == .badRequest)
            let patched = try await client.send(.patch, headers: owner, to: URI(string: "/api/mcp/servers/\(keyedId)")) {
                $0.body = .init(string: "{\"credentialPatch\":{\"removeHeaderNames\":[\"x-api-key\",5],\"upsertHeaders\":{\"B-Key\":\"v\"}}}")
            }
            #expect(patched.status == .ok)
            #expect(text(patched) == "{\"id\":\"\(keyedId)\",\"name\":\"Renamed\",\"provider\":null,\"authMode\":null,\"oauthStatus\":null,\"endpointUrl\":\"https://example.com/mcp\",\"hasCredentials\":true,\"credentialHeaderNames\":[\"B-Key\"],\"assignment\":null}")
            let ghost = try await client.send(.patch, headers: owner, to: "/api/mcp/servers/ghost") { $0.body = .init(string: "{}") }
            #expect(ghost.status == .notFound)
            #expect(text(ghost) == "{\"error\":\"MCP server not found\",\"code\":\"managed_mcp_server_not_found\"}")

            let catalog = try await client.get(URI(string: "/api/mcp/agents/\(fixture.agentId)"), headers: member)
            #expect(catalog.status == .ok)
            let agentName = fixture.accounts.oauth.agentRuntimeInfo(id: fixture.agentId)?.name ?? ""
            let agentDisplay = fixture.accounts.oauth.agentRuntimeInfo(id: fixture.agentId)?.displayName ?? ""
            #expect(text(catalog).hasPrefix("{\"agent\":{\"id\":\"\(fixture.agentId)\",\"name\":\"\(agentName)\",\"displayName\":\"\(agentDisplay)\"},\"servers\":[{\"id\":\"\(notionId)\""))
            let unknownAgent = try await client.get("/api/mcp/agents/not-a-uuid", headers: member)
            #expect(unknownAgent.status == .notFound)
            #expect(text(unknownAgent) == "{\"error\":\"Agent not found\"}")
            let absentAgent = try await client.get("/api/mcp/agents/22222222-2222-4222-8222-222222222222", headers: member)
            #expect(text(absentAgent) == "{\"error\":\"Agent not found\",\"code\":\"managed_mcp_agent_not_found\"}")

            let assigned = try await client.send(.put, headers: owner, to: URI(string: "/api/mcp/agents/\(fixture.agentId)/assignments")) {
                $0.body = .init(string: "{\"assignments\":[{\"mcpServerId\":\"\(notionId)\",\"allowedTools\":[\"a\",\"b\"]},{\"mcpServerId\":\"\(keyedId)\",\"enabled\":false}]}")
            }
            #expect(assigned.status == .ok)
            #expect(text(assigned) == "{\"ok\":true,\"assignments\":[{\"mcpServerId\":\"\(notionId)\",\"enabled\":true,\"allowedTools\":[\"a\",\"b\"]},{\"mcpServerId\":\"\(keyedId)\",\"enabled\":false,\"allowedTools\":null}]}")
            let noAssignments = try await client.send(.put, headers: owner, to: URI(string: "/api/mcp/agents/\(fixture.agentId)/assignments")) {
                $0.body = .init(string: "{}")
            }
            #expect(text(noAssignments) == "{\"error\":\"assignments is required\",\"code\":\"managed_mcp_request_invalid\"}")
            let single = try await client.send(.put, headers: owner, to: URI(string: "/api/mcp/agents/\(fixture.agentId)/assignments/\(notionId)")) {
                $0.body = .init(string: "{\"enabled\":false,\"allowedTools\":[]}")
            }
            #expect(text(single) == "{\"assignment\":{\"mcpServerId\":\"\(notionId)\",\"enabled\":false,\"allowedTools\":[]}}")

            let tested = try await client.send(.post, headers: owner, to: "/api/mcp/servers/test-configuration") {
                $0.body = .init(string: "{\"endpointUrl\":\"https://example.com/mcp\"}")
            }
            #expect(text(tested) == "{\"ok\":true}")
            let testedMember = try await client.send(.post, headers: member, to: "/api/mcp/servers/test-configuration") { $0.body = .init(string: "{}") }
            #expect(text(testedMember) == "{\"error\":\"Only server owners and admins can test MCP servers\"}")

            let removed = try await client.delete(URI(string: "/api/mcp/servers/\(notionId)"), headers: owner)
            #expect(text(removed) == "{\"ok\":true}")
            let removedAgain = try await client.delete(URI(string: "/api/mcp/servers/\(notionId)"), headers: owner)
            #expect(removedAgain.status == .notFound)
        }
    }
}

@Test func managedMCPOAuthDocumentsKeepTheirHeaderSetsAndBodies() async throws {
    let fixture = makeCatalogFixture("02")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let callback = try await client.get("/api/mcp/oauth/callback")
            #expect(callback.status == .badRequest)
            #expect(text(callback) == "<!doctype html><html><head><title>RAFT MCP</title></head><body><main><h1>RAFT</h1><p>MCP was not connected.</p><p>Close window</p><div id=\"raft-managed-mcp-oauth-result\"></div><script type=\"application/json\" id=\"managed-mcp-oauth-result\">{}</script></main></body></html>")
            #expect(callback.headers[.contentType] == "text/html; charset=utf-8")
            #expect(callback.headers[HTTPField.Name("Content-Security-Policy")!] == "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'")
            #expect(callback.headers[.cacheControl] == "no-store")
            #expect(callback.headers[HTTPField.Name("X-Robots-Tag")!] == nil)

            let metadata = try await client.get("/api/mcp/oauth/client-metadata")
            let base = fixture.accounts.oauthFlows.deploymentConfiguration.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            #expect(text(metadata) == "{\"client_id\":\"\(base)/api/mcp/oauth/client-metadata\",\"redirect_uris\":[\"\(base)/api/mcp/oauth/callback\"]}")
            #expect(metadata.headers[.cacheControl] == "no-store")
            #expect(metadata.headers[.contentType] == "application/json; charset=utf-8")
            #expect(metadata.headers[HTTPField.Name("X-Robots-Tag")!] != nil)
        }
    }
}

@Test func reminderRoutesKeepTheLegacyBodiesAndOrder() async throws {
    let fixture = makeCatalogFixture("03")
    let accounts = fixture.accounts
    let machineId = accounts.registerMachine(serverId: fixture.serverId, userId: fixture.ownerId, name: "catalog-machine")
    accounts.assignAgentMachineForTesting(agentId: fixture.agentId, machineId: machineId)
    let machineKey = try #require(accounts.machineAPIKey(machineId: machineId))
    let agentKey = accounts.mintAgentCredential(agentId: fixture.agentId, scopes: ["read", "tasks"], name: "catalog-key")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            let machine = bearer(machineKey)
            let agent = bearer(agentKey)
            let base = "/internal/agent/\(fixture.agentId)/reminders"

            let created = try await client.send(.post, headers: machine, to: URI(string: base)) {
                $0.body = .init(string: "{\"title\":\" Stand up \",\"msgId\":\"m-1\",\"delaySeconds\":600}")
            }
            #expect(created.status == .ok)
            let reminderId = (((try JSONSerialization.jsonObject(with: Data(text(created).utf8))) as? [String: Any])?["reminder"] as? [String: Any])?["id"] as? String ?? ""
            #expect(text(created) == "{\"reminder\":{\"id\":\"\(reminderId)\",\"reminderId\":\"\(reminderId)\",\"ownerAgentId\":null,\"status\":\"scheduled\",\"version\":1,\"title\":\"Stand up\",\"fireAt\":null}}")

            let noTitle = try await client.send(.post, headers: machine, to: URI(string: base)) { $0.body = .init(string: "{}") }
            #expect(text(noTitle) == "{\"error\":\"title is required\"}")
            let noMsg = try await client.send(.post, headers: machine, to: URI(string: base)) { $0.body = .init(string: "{\"title\":\"t\"}") }
            #expect(text(noMsg) == "{\"error\":\"msgId is required for agent-created reminders\"}")
            let noFire = try await client.send(.post, headers: machine, to: URI(string: base)) { $0.body = .init(string: "{\"title\":\"t\",\"msgId\":\"m\",\"delaySeconds\":-1}") }
            #expect(text(noFire) == "{\"error\":\"fireAt or delaySeconds is required\"}")

            let listed = try await client.get(URI(string: base), headers: machine)
            #expect(redactingTimestamps(text(listed)) == "{\"reminders\":[{\"id\":\"\(reminderId)\",\"reminderId\":\"\(reminderId)\",\"ownerAgentId\":\"\(fixture.agentId)\",\"status\":\"scheduled\",\"version\":1,\"title\":\"Stand up\",\"fireAt\":\"T\"}]}")
            let badStatus = try await client.get(URI(string: base + "?status=nope"), headers: machine)
            #expect(text(badStatus) == "{\"error\":\"Invalid status filter\"}")

            let conflict = try await client.send(.delete, headers: machine, to: URI(string: "\(base)/\(reminderId)")) {
                $0.body = .init(string: "{\"expectedVersion\":9}")
            }
            #expect(conflict.status == .conflict)
            #expect(text(conflict) == "{\"error\":\"Reminder version conflict\",\"currentVersion\":1}")
            let canceled = try await client.send(.delete, headers: machine, to: URI(string: "\(base)/\(reminderId)")) {
                $0.body = .init(string: "{\"expectedVersion\":1}")
            }
            #expect(text(canceled) == "{\"reminder\":{\"id\":\"\(reminderId)\",\"reminderId\":\"\(reminderId)\",\"ownerAgentId\":null,\"status\":\"canceled\",\"version\":2,\"title\":\"Stand up\",\"fireAt\":null}}")
            let missing = try await client.send(.delete, headers: machine, to: URI(string: "\(base)/ghost")) { $0.body = .init(string: "{}") }
            #expect(text(missing) == "{\"error\":\"Reminder not found\"}")
            let snoozeCanceled = try await client.send(.post, headers: machine, to: URI(string: "\(base)/\(reminderId)/snooze")) {
                $0.body = .init(string: "{\"delaySeconds\":5}")
            }
            #expect(snoozeCanceled.status == .notFound)

            // The agent-api surface refuses the snooze of a canceled reminder with 409.
            let agentSnooze = try await client.send(.post, headers: agent, to: URI(string: "/internal/agent-api/reminders/\(reminderId)/snooze")) {
                $0.body = .init(string: "{\"delaySeconds\":5}")
            }
            #expect(agentSnooze.status == .conflict)
            #expect(text(agentSnooze) == "{\"error\":\"cannot snooze a canceled reminder\"}")
            let agentLog = try await client.get(URI(string: "/internal/agent-api/reminders/\(reminderId)/log"), headers: agent)
            #expect(Set((((try JSONSerialization.jsonObject(with: Data(text(agentLog).utf8))) as? [String: Any])?["events"] as? [[String: Any]] ?? []).compactMap { $0["eventType"] as? String }) == ["scheduled", "canceled"])
            #expect(text(agentLog).hasPrefix("{\"events\":[{\"eventType\":\""))

            let agentCreated = try await client.send(.post, headers: agent, to: "/internal/agent-api/reminders") {
                $0.body = .init(string: "{\"title\":\"Agent made\",\"msgId\":\"m-2\",\"fireAt\":\"2030-01-01T00:00:00Z\"}")
            }
            let agentReminderId = (((try JSONSerialization.jsonObject(with: Data(text(agentCreated).utf8))) as? [String: Any])?["reminder"] as? [String: Any])?["id"] as? String ?? ""
            #expect(text(agentCreated) == "{\"reminder\":{\"id\":\"\(agentReminderId)\",\"reminderId\":\"\(agentReminderId)\",\"ownerAgentId\":null,\"status\":\"scheduled\",\"version\":1,\"title\":\"Agent made\",\"fireAt\":null}}")
            let agentList = try await client.get(URI(string: "/internal/agent-api/reminders?status=scheduled"), headers: agent)
            #expect(text(agentList) == "{\"reminders\":[{\"id\":\"\(agentReminderId)\",\"reminderId\":\"\(agentReminderId)\",\"ownerAgentId\":\"\(fixture.agentId)\",\"status\":\"scheduled\",\"version\":1,\"title\":\"Agent made\",\"fireAt\":\"2030-01-01T00:00:00Z\"}]}")
            let agentUpdated = try await client.send(.patch, headers: agent, to: URI(string: "/internal/agent-api/reminders/\(agentReminderId)")) {
                $0.body = .init(string: "{\"title\":\"Renamed\"}")
            }
            #expect(text(agentUpdated) == "{\"reminder\":{\"id\":\"\(agentReminderId)\",\"reminderId\":\"\(agentReminderId)\",\"ownerAgentId\":\"\(fixture.agentId)\",\"status\":\"scheduled\",\"version\":2,\"title\":\"Renamed\",\"fireAt\":\"2030-01-01T00:00:00Z\"}}")
            let agentEmptyUpdate = try await client.send(.patch, headers: agent, to: URI(string: "/internal/agent-api/reminders/\(agentReminderId)")) {
                $0.body = .init(string: "{}")
            }
            #expect(agentEmptyUpdate.status == .conflict)
            #expect(text(agentEmptyUpdate) == "{\"error\":\"no update fields\"}")
            let noToken = try await client.get("/internal/agent-api/reminders")
            #expect(noToken.status == .unauthorized)
            #expect(text(noToken) == "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")

            let owner = bearer(fixture.ownerToken, serverId: fixture.serverId)
            let ownerList = try await client.get(URI(string: "/api/reminders?ownerAgentId=\(fixture.agentId)"), headers: owner)
            #expect(redactingTimestamps(text(ownerList)).hasPrefix("{\"reminders\":[{\"id\":\""))
            #expect(redactingTimestamps(text(ownerList)).contains("\",\"title\":\"Stand up\",\"ownerAgentId\":\"\(fixture.agentId)\",\"fireAt\":\"T\"}"))
            let member = bearer(fixture.memberToken, serverId: fixture.serverId)
            let forbidden = try await client.get(URI(string: "/api/reminders?ownerAgentId=\(fixture.agentId)"), headers: member)
            #expect(forbidden.status == .forbidden)
            #expect(text(forbidden) == "{\"error\":\"Forbidden\"}")
            let memberAll = try await client.get("/api/reminders", headers: member)
            #expect(text(memberAll) == "{\"reminders\":[]}")
        }
    }
}

@Test func savedMessageWriteAndAgentHistoryKeepTheirBytes() async throws {
    let fixture = makeCatalogFixture("04")
    let accounts = fixture.accounts
    let channelName = "catalog-room"
    let channelId = accounts.oauth.createChannel(serverId: fixture.serverId, name: channelName, creatorUserId: fixture.ownerId)
    accounts.addPostableChannel(serverId: fixture.serverId, channelId: channelId, memberId: fixture.ownerId, name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: fixture.ownerId)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: fixture.agentId)
    let readKey = accounts.mintAgentCredential(agentId: fixture.agentId, scopes: ["read"], name: "catalog-read")
    let message = accounts.oauth.createMessageRecord(channelId: channelId, content: "hello \"catalog\"", senderId: fixture.ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = bearer(fixture.ownerToken, serverId: fixture.serverId)
            let saved = try await client.send(.post, headers: owner, to: "/api/channels/saved") {
                $0.body = .init(string: "{\"messageId\":\"\(message.id)\"}")
            }
            #expect(saved.status == .ok)
            #expect(text(saved) == "{\"ok\":true}")
            let unknown = try await client.send(.post, headers: owner, to: "/api/channels/saved") { $0.body = .init(string: "{\"messageId\":\"ghost\"}") }
            #expect(unknown.status == .notFound)
            #expect(text(unknown) == "{\"error\":\"Message not found\"}")
            let notMember = try await client.send(.post, headers: bearer(fixture.memberToken, serverId: "33333333-3333-4333-8333-999999999999"), to: "/api/channels/saved") {
                $0.body = .init(string: "{}")
            }
            #expect(text(notMember) == "{\"error\":\"Not a member of this server\"}")

            let read = try await client.get(URI(string: "/internal/agent-api/history?channel=%23\(channelName)"), headers: bearer(readKey))
            #expect(read.status == .ok)
            let body = text(read)
            let rows = ((try JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["messages"] as? [[String: Any]]
            let senderName = rows?.first?["senderName"] as? String ?? ""
            #expect(!senderName.isEmpty)
            #expect(redactingTimestamps(body) == "{\"messages\":[{\"id\":\"\(message.id)\",\"channelId\":\"\(channelId)\",\"content\":\"hello \\\"catalog\\\"\",\"seq\":\(message.seq),\"senderType\":\"user\",\"senderId\":\"\(fixture.ownerId)\",\"senderName\":\"\(senderName)\",\"senderTimezone\":null,\"createdAt\":\"T\",\"attachments\":[],\"mentioned\":false}],\"has_more\":false,\"has_older\":false,\"has_newer\":false,\"last_read_seq\":0,\"model_seen_up_to_seq\":\(message.seq),\"target\":\"#\(channelName)\",\"channel_card\":{\"id\":\"\(channelId)\",\"name\":\"\(channelName)\",\"type\":\"channel\",\"description\":null,\"archived\":false}}")

            let unreadRead = try await client.get(URI(string: "/internal/agent-api/history?channel=%23\(channelName)&unread=true&after=1"), headers: bearer(readKey))
            #expect(unreadRead.status == .badRequest)
            #expect(text(unreadRead) == "{\"error\":\"unread cannot be combined with an anchor\",\"errorCode\":\"INVALID_ARG\",\"suggestedNextAction\":\"raft message read --target '#\(channelName)' --unread\"}")
            let badConsume = try await client.get(URI(string: "/internal/agent-api/history?channel=%23\(channelName)&consume=maybe"), headers: bearer(readKey))
            #expect(text(badConsume) == #"{"error":"Invalid agent-api historyRead query","code":"agent_api_contract_invalid","issues":[{"path":"consume","message":"Invalid option: expected one of \"true\"|\"false\""}]}"#)
            let noChannel = try await client.get("/internal/agent-api/history", headers: bearer(readKey))
            #expect(text(noChannel) == #"{"error":"Invalid agent-api historyRead query","code":"agent_api_contract_invalid","issues":[{"path":"channel","message":"Invalid input: expected string, received undefined"}]}"#)
            let hidden = try await client.get("/internal/agent-api/history?channel=%23ghost", headers: bearer(readKey))
            #expect(text(hidden) == "{\"error\":\"Channel not found or not visible\"}")
            let noAuth = try await client.get("/internal/agent-api/history?channel=%23\(channelName)")
            #expect(noAuth.status == .unauthorized)
            #expect(text(noAuth) == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
            let badAnchor = try await client.get(URI(string: "/internal/agent-api/history?channel=%23\(channelName)&around=zzzz"), headers: bearer(readKey))
            #expect(text(badAnchor) == "{\"error\":\"Message anchor must be a seq, full UUID, or 8-character short id in #\(channelName): zzzz\",\"errorCode\":\"INVALID_ARG\"}")
            let missingAnchor = try await client.get(URI(string: "/internal/agent-api/history?channel=%23\(channelName)&before=22222222-2222-4222-8222-222222222222"), headers: bearer(readKey))
            #expect(text(missingAnchor) == "{\"error\":\"Message not found in #\(channelName): 22222222-2222-4222-8222-222222222222\",\"errorCode\":\"NOT_FOUND\"}")
        }
    }
}
