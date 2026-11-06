import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

// Coverage for the `agents.api` groups the existing suite does not exercise:
// skills/workspace/activity machine surfaces with typed failure statuses,
// RFC 071 human Start/Reset controls and the terminal-breaker lift rule,
// assign-machine vs an active migration, onboarding Cindy create/refusal, and
// the v2 protocol field-pointing rejection for a malformed connection id.

private struct AgentsGapFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let creatorId: String
    let creatorEmail: String
    let adminId: String
    let adminEmail: String
    let viewerId: String
    let viewerEmail: String
    let agentId: String
    let machineId: String
    let targetMachineId: String
}

private func makeAgentsGapFixture(_ suffix: Int) -> AgentsGapFixture {
    let accounts = EmailLoginDirectory()
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 1_090_000 + suffix)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 1_090_000 + suffix)
    let creatorId = String(format: "11111111-1111-4111-8111-%012d", 1_090_100 + suffix)
    let adminId = String(format: "11111111-1111-4111-8111-%012d", 1_090_200 + suffix)
    let viewerId = String(format: "11111111-1111-4111-8111-%012d", 1_090_300 + suffix)
    let ownerEmail = "agents-gap-owner-\(suffix)@slock.test"
    let creatorEmail = "agents-gap-creator-\(suffix)@slock.test"
    let adminEmail = "agents-gap-admin-\(suffix)@slock.test"
    let viewerEmail = "agents-gap-viewer-\(suffix)@slock.test"
    for (id, email) in [
        (ownerId, ownerEmail),
        (creatorId, creatorEmail),
        (adminId, adminEmail),
        (viewerId, viewerEmail),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "agents-gap-\(suffix)", name: "Agents Gap \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: creatorId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: viewerId, role: "member")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "agents-gap-machine-\(suffix)")
    let targetMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "agents-gap-target-\(suffix)")
    accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: ["codex"])
    accounts.setMachineRuntimesForTesting(machineId: targetMachine, runtimes: ["codex"])
    accounts.setMachineOnline(machineId: machine, online: true)
    accounts.setMachineOnline(machineId: targetMachine, online: true)
    let agent = accounts.oauth.createAgent(
        serverId: serverId,
        name: "agents-gap-agent-\(suffix)",
        creatorUserId: creatorId,
        runtime: "codex"
    )
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    return AgentsGapFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        creatorId: creatorId,
        creatorEmail: creatorEmail,
        adminId: adminId,
        adminEmail: adminEmail,
        viewerId: viewerId,
        viewerEmail: viewerEmail,
        agentId: agent,
        machineId: machine,
        targetMachineId: targetMachine
    )
}

private func agentsGapLogin(_ client: any TestClient, _ email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func agentsGapHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func agentsGapObject(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func withAgentsGapApp(
    _ fixture: AgentsGapFixture,
    _ body: (any TestClient, HTTPFields, HTTPFields, HTTPFields) async throws -> Void
) async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await agentsGapLogin(client, fixture.ownerEmail)
            let creator = try await agentsGapLogin(client, fixture.creatorEmail)
            let admin = try await agentsGapLogin(client, fixture.adminEmail)
            try await body(
                client,
                agentsGapHeaders(owner, fixture.serverId),
                agentsGapHeaders(creator, fixture.serverId),
                agentsGapHeaders(admin, fixture.serverId)
            )
        }
    }
}

// MARK: - Skills surface and typed failure statuses (upstream 5137, 5565, 5688, 5778, 5830)

@Test func agentSkillsSurfaceReturnsWorkspaceSkillsAndTypesFailures() async throws {
    let fixture = makeAgentsGapFixture(5201)
    let recorder = AgentsGapRecorder()
    try await withAgentsGapApp(fixture) { client, _, creatorHeaders, _ in
        let empty = try await client.get(URI(string: "/api/agents/\(fixture.agentId)/skills"), headers: creatorHeaders)
        #expect(empty.status == .ok)
        #expect(agentsGapObject(empty)["global"] is [Any])
        #expect(agentsGapObject(empty)["workspace"] is [Any])

        fixture.accounts.agentSkillsProvider = { agentId in
            recorder.record("skills|\(agentId)")
            return .ok("{\"global\":[],\"workspace\":[{\"name\":\"secret-skill\",\"path\":\"skills/secret-skill/SKILL.md\"}]}")
        }
        let listed = try await client.get(URI(string: "/api/agents/\(fixture.agentId)/skills"), headers: creatorHeaders)
        #expect(listed.status == .ok)
        let workspace = agentsGapObject(listed)["workspace"] as? [[String: Any]] ?? []
        #expect(workspace.first?["name"] as? String == "secret-skill")
        #expect(recorder.recorded.filter { $0.hasPrefix("skills|") }.count == 1)

        // Non-local owner is a closed machine-affinity error and the handler is
        // never entered.
        fixture.accounts.agentHasMachineLocally = { _ in false }
        recorder.reset()
        let affinity = try await client.get(URI(string: "/api/agents/\(fixture.agentId)/skills"), headers: creatorHeaders)
        #expect(affinity.status == .conflict)
        let affinityBody = agentsGapObject(affinity)
        #expect(affinityBody["code"] as? String == "machine_offline")
        #expect(affinityBody["machineAffinityRoute"] as? String == "owner_missing")
        #expect(recorder.recorded.filter { $0.hasPrefix("skills|") }.count == 0)

        // Offline daemon.
        fixture.accounts.agentHasMachineLocally = { _ in true }
        fixture.accounts.agentSkillsProvider = { _ in .machineOffline }
        let offline = try await client.get(URI(string: "/api/agents/\(fixture.agentId)/skills"), headers: creatorHeaders)
        #expect(offline.status == .conflict)
        #expect(agentsGapObject(offline)["code"] as? String == "machine_offline")

        // Timed-out daemon.
        fixture.accounts.agentSkillsProvider = { _ in .machineTimeout }
        let timeout = try await client.get(URI(string: "/api/agents/\(fixture.agentId)/skills"), headers: creatorHeaders)
        #expect(timeout.status == .init(code: 504, reasonPhrase: "Gateway Timeout"))
        #expect(agentsGapObject(timeout)["code"] as? String == "daemon_timeout")

        // Forged replay headers are rejected before the local owner handler.
        fixture.accounts.agentSkillsProvider = { _ in
            recorder.increment("skills-after-replay")
            return .ok("{\"global\":[],\"workspace\":[]}")
        }
        var replayHeaders = creatorHeaders
        replayHeaders[HTTPField.Name("X-Raft-Replica-Replay")!] = "1"
        replayHeaders[HTTPField.Name("X-Raft-Replica-Replay-Machine")!] = fixture.machineId
        replayHeaders[HTTPField.Name("X-Raft-Replica-Replay-Timestamp")!] = "1700000000"
        replayHeaders[HTTPField.Name("X-Raft-Replica-Replay-Signature")!] = "forged"
        let forged = try await client.get(URI(string: "/api/agents/\(fixture.agentId)/skills"), headers: replayHeaders)
        #expect(forged.status == .badRequest)
        let forgedBody = agentsGapObject(forged)
        #expect(forgedBody["code"] as? String == "invalid_replica_replay_signature")
        #expect(forgedBody["machineAffinityRoute"] as? String == "owner_not_local")
        #expect(recorder.count("skills-after-replay") == 0)
    }
}

@Test func agentsApiGapPrivateSurfacesAllowCreatorAndAdminsOnly() async throws {
    let fixture = makeAgentsGapFixture(5202)
    fixture.accounts.agentActivityLogProvider = { _, _ in .ok("[]") }
    fixture.accounts.agentActivitySummariesProvider = { _, _, _, _ in .ok("{\"summaries\":[],\"next\":null}") }
    fixture.accounts.agentSkillsProvider = { _ in .ok("{\"global\":[],\"workspace\":[]}") }
    fixture.accounts.agentWorkspaceTreeProvider = { _, _, _ in .ok("[]") }
    try await withAgentsGapApp(fixture) { client, ownerHeaders, creatorHeaders, adminHeaders in
        let viewer = try await agentsGapLogin(client, fixture.viewerEmail)
        let viewerHeaders = agentsGapHeaders(viewer, fixture.serverId)
        for route in [
            "/api/agents/\(fixture.agentId)/activity-log",
            "/api/agents/\(fixture.agentId)/activity-summaries",
            "/api/agents/\(fixture.agentId)/workspace-files",
            "/api/agents/\(fixture.agentId)/skills",
        ] {
            let denied = try await client.get(URI(string: route), headers: viewerHeaders)
            #expect(denied.status == .forbidden, "\(route) viewer")
            for headers in [ownerHeaders, creatorHeaders, adminHeaders] {
                let allowed = try await client.get(URI(string: route), headers: headers)
                #expect(allowed.status == .ok, "\(route) creator/admin")
            }
        }
    }
}

// MARK: - Workspace files (upstream 5288, 5327)

@Test func agentWorkspaceFilesForwardsTreeOptionsAndClassifiesFailures() async throws {
    let fixture = makeAgentsGapFixture(5203)
    let recorder = AgentsGapRecorder()
    fixture.accounts.agentWorkspaceTreeProvider = { agentId, dirPath, includeHidden in
        recorder.record("tree|\(agentId)|\(dirPath ?? "nil")|\(includeHidden)")
        return .ok("[{\"name\":\".gitignore\",\"path\":\".gitignore\",\"isDirectory\":false,\"size\":12,\"isHidden\":true}]")
    }
    try await withAgentsGapApp(fixture) { client, _, creatorHeaders, _ in
        let listed = try await client.get(
            URI(string: "/api/agents/\(fixture.agentId)/workspace-files?dirPath=notes&includeHidden=true"),
            headers: creatorHeaders
        )
        #expect(listed.status == .ok)
        let files = agentsGapObject(listed)["files"] as? [[String: Any]] ?? []
        #expect(files.first?["name"] as? String == ".gitignore")
        #expect(files.first?["isHidden"] as? Bool == true)
        #expect(recorder.recorded == ["tree|\(fixture.agentId)|notes|true"])

        fixture.accounts.agentWorkspaceTreeProvider = { _, _, _ in .machineUnassigned }
        let unassigned = try await client.get(
            URI(string: "/api/agents/\(fixture.agentId)/workspace-files"),
            headers: creatorHeaders
        )
        #expect(unassigned.status == .conflict)
        #expect(agentsGapObject(unassigned)["code"] as? String == "machine_unassigned")

        fixture.accounts.agentWorkspaceTreeProvider = { _, _, _ in .machineOffline }
        let offline = try await client.get(
            URI(string: "/api/agents/\(fixture.agentId)/workspace-files"),
            headers: creatorHeaders
        )
        #expect(offline.status == .conflict)
        let offlineBody = agentsGapObject(offline)
        #expect(offlineBody["code"] as? String == "machine_offline")
        #expect(offlineBody["error"] as? String == "Agent has no connected machine")

        fixture.accounts.agentWorkspaceReadProvider = { _, path in
            recorder.record("read|\(path ?? "nil")")
            return .ok("{\"content\":\"secret\",\"binary\":false,\"size\":6,\"mimeType\":\"text/plain\",\"encoding\":\"utf8\"}")
        }
        let read = try await client.get(
            URI(string: "/api/agents/\(fixture.agentId)/workspace-files/read?path=MEMORY.md"),
            headers: creatorHeaders
        )
        #expect(read.status == .ok)
        #expect(agentsGapObject(read)["content"] as? String == "secret")
        #expect(recorder.recorded.filter { $0.hasPrefix("read|") }.count == 1)

        fixture.accounts.agentWorkspaceReadProvider = { _, _ in .machineTimeout }
        let timedOut = try await client.get(
            URI(string: "/api/agents/\(fixture.agentId)/workspace-files/read?path=MEMORY.md"),
            headers: creatorHeaders
        )
        #expect(timedOut.status == .init(code: 504, reasonPhrase: "Gateway Timeout"))
        let timeoutBody = agentsGapObject(timedOut)
        #expect(timeoutBody["code"] as? String == "daemon_timeout")
        #expect(timeoutBody["error"] as? String == "Workspace file read request timed out")
    }
}

// MARK: - Activity log and summaries (upstream 5211, 5252)

@Test func agentActivityLogAndSummariesRedactHiddenTriggers() async throws {
    let fixture = makeAgentsGapFixture(5204)
    let publicChannel = fixture.accounts.oauth.createChannel(
        serverId: fixture.serverId,
        name: "gap-public",
        creatorUserId: fixture.ownerId
    )
    fixture.accounts.addPostableChannel(
        serverId: fixture.serverId,
        channelId: publicChannel,
        memberId: fixture.ownerId,
        name: "gap-public"
    )
    let privateChannel = fixture.accounts.oauth.createChannel(
        serverId: fixture.serverId,
        name: "gap-secret",
        creatorUserId: fixture.creatorId
    )
    fixture.accounts.addPostableChannel(
        serverId: fixture.serverId,
        channelId: privateChannel,
        memberId: fixture.creatorId,
        kind: "private",
        name: "gap-secret"
    )
    let dmChannel = UUID().uuidString.lowercased()
    let recorder = AgentsGapRecorder()

    fixture.accounts.agentActivityLogProvider = { agentId, limit in
        recorder.record("log|\(agentId)|\(limit.map(String.init) ?? "nil")")
        let entry = "{\"entry\":{\"kind\":\"tool_start\",\"toolName\":\"Bash\",\"toolInput\":\"pnpm test\",\"callId\":\"toolu_1\"}}"
        let tool = "{\"entry\":{\"kind\":\"status\",\"activity\":\"working\",\"detail\":\"Tool finished\",\"detailKind\":\"tool_end\",\"tool\":{\"callId\":\"toolu_1\",\"ok\":true,\"durationMs\":2500,\"exitCode\":1}}}"
        return .ok("[\(entry),\(tool)]")
    }
    fixture.accounts.agentActivitySummariesProvider = { agentId, limit, beforeEndedAt, beforeId in
        recorder.record("summaries|\(agentId)|\(limit)|\(beforeEndedAt.map(String.init) ?? "nil")|\(beforeId ?? "nil")")
        let summaries = [
            "{\"startedAt\":5,\"endedAt\":6,\"outcome\":\"completed\",\"trigger\":{\"target\":\"#gap-public\",\"channelId\":\"\(publicChannel)\",\"sender\":\"richard\",\"messageId\":\"m1\"}}",
            "{\"startedAt\":3,\"endedAt\":4,\"outcome\":\"completed\",\"trigger\":{\"target\":\"#gap-secret\",\"channelId\":\"\(privateChannel)\",\"sender\":\"secret-sender\",\"messageId\":\"m2\"}}",
            "{\"startedAt\":1,\"endedAt\":2,\"outcome\":\"completed\",\"trigger\":{\"target\":\"dm:@hidden-peer\",\"channelId\":\"\(dmChannel)\",\"sender\":\"hidden-peer\",\"messageId\":\"m3\"}}",
            "{\"startedAt\":0,\"endedAt\":1,\"outcome\":\"completed\"}",
        ]
        return .ok("{\"summaries\":[\(summaries.joined(separator: ","))],\"next\":\"1:00000000-0000-4000-8000-000000000001\"}")
    }

    try await withAgentsGapApp(fixture) { client, ownerHeaders, _, _ in
        let log = try await client.get(
            URI(string: "/api/agents/\(fixture.agentId)/activity-log?limit=2"),
            headers: ownerHeaders
        )
        #expect(log.status == .ok)
        let logBody = try #require((try? JSONSerialization.jsonObject(with: Data((log.body.string ?? "").utf8))) as? [[String: Any]])
        #expect(logBody.count == 2)
        let tool = logBody[1]["entry"] as? [String: Any]
        let toolFields = tool?["tool"] as? [String: Any]
        #expect(toolFields?["callId"] as? String == "toolu_1")
        #expect(toolFields?["ok"] as? Bool == true)
        #expect(toolFields?["durationMs"] as? Int == 2500)
        #expect(toolFields?["exitCode"] as? Int == 1)

        let summaries = try await client.get(
            URI(string: "/api/agents/\(fixture.agentId)/activity-summaries?limit=4&before=99:00000000-0000-4000-8000-000000000009"),
            headers: ownerHeaders
        )
        #expect(summaries.status == .ok)
        #expect(recorder.recorded.contains("summaries|\(fixture.agentId)|4|99|00000000-0000-4000-8000-000000000009"))
        let summariesBody = agentsGapObject(summaries)
        #expect(summariesBody["next"] as? String == "1:00000000-0000-4000-8000-000000000001")
        let rows = summariesBody["summaries"] as? [[String: Any]] ?? []
        let triggers = rows.map { $0["trigger"] as? [String: Any] }
        #expect(triggers[0]?["target"] as? String == "#gap-public")
        #expect(triggers[1]?["hidden"] as? String == "private_channel")
        #expect(triggers[2]?["hidden"] as? String == "dm")
        #expect(triggers[3] == nil)
        let serialized = summaries.body.string ?? ""
        #expect(!serialized.contains("gap-secret"))
        #expect(!serialized.contains("secret-sender"))
        #expect(!serialized.contains("hidden-peer"))
        #expect(recorder.recorded.contains("log|\(fixture.agentId)|2"))
    }
}

// MARK: - RFC 071 human controls (upstream 6815)

@Test func agentStartAndResetDispatchExplicitHumanControls() async throws {
    let fixture = makeAgentsGapFixture(5205)
    let recorder = AgentsGapRecorder()
    fixture.accounts.agentStartControlDispatch = { agentId, control in
        recorder.record("start|\(agentId)|\(control)")
    }
    fixture.accounts.agentResetDispatch = { agentId, mode, control in
        recorder.record("reset|\(agentId)|\(mode)|\(control)")
    }
    try await withAgentsGapApp(fixture) { client, _, creatorHeaders, _ in
        let start = try await client.send(
            .post,
            headers: creatorHeaders,
            to: URI(string: "/api/agents/\(fixture.agentId)/start")
        )
        #expect(start.status == .ok)
        #expect(recorder.recorded == ["start|\(fixture.agentId)|human_start"])

        let reset = try await client.send(
            .post,
            headers: creatorHeaders,
            to: URI(string: "/api/agents/\(fixture.agentId)/reset")
        ) { request in
            request.body = .init(string: "{\"mode\":\"session\"}")
        }
        #expect(reset.status == .accepted)
        #expect(recorder.recorded.last == "reset|\(fixture.agentId)|session|human_reset")
    }
}

@Test func agentPatchLiftsTerminalBreakerOnlyOnRealRuntimeChange() async throws {
    let fixture = makeAgentsGapFixture(5206)
    let recorder = AgentsGapRecorder()
    fixture.accounts.agentConfigLiftDispatch = { agentId, changed in
        recorder.record("lift|\(agentId)|\(changed)")
    }
    try await withAgentsGapApp(fixture) { client, _, creatorHeaders, _ in
        func patch(_ body: String) async throws -> ClientResponse {
            try await client.send(.patch, headers: creatorHeaders, to: URI(string: "/api/agents/\(fixture.agentId)")) { request in
                request.body = .init(string: body)
            }
        }
        // Presence alone is not a change.
        fixture.accounts.oauth.updateAgentRuntime(
            id: fixture.agentId,
            runtimeConfigJSON: "{\"version\":1,\"runtime\":\"codex\",\"model\":{\"kind\":\"preset\",\"id\":\"gpt-5.6-sol\"},\"mode\":{\"kind\":\"restart\"},\"reasoningEffort\":null,\"envVars\":{}}",
            envVarsJSON: "{}"
        )
        recorder.reset()
        let sameModel = try await patch("{\"model\":\"gpt-5.6-sol\"}")
        #expect(sameModel.status == .ok)
        #expect(recorder.recorded.last == "lift|\(fixture.agentId)|false")

        let changedEffort = try await patch("{\"reasoningEffort\":\"high\"}")
        #expect(changedEffort.status == .ok)
        #expect(recorder.recorded.last == "lift|\(fixture.agentId)|true")
    }
}

// MARK: - Migration vs assign-machine (upstream 2515)

@Test func agentAssignMachineRefusesWhileMigrationIsActive() async throws {
    let fixture = makeAgentsGapFixture(5207)
    let ref = "mig_" + "a" + String(format: "%05d", 5207) + String(repeating: "b", count: 16)
    fixture.accounts.seedMachineMigrationForTesting(
        agentId: fixture.agentId,
        serverId: fixture.serverId,
        supportRef: ref,
        revision: 1,
        state: "in_transit",
        sourceMachineId: fixture.machineId,
        targetMachineId: fixture.targetMachineId,
        transportGeneration: "gen-assign"
    )
    try await withAgentsGapApp(fixture) { client, _, creatorHeaders, _ in
        func assign(_ machineId: String?) async throws -> ClientResponse {
            let body = machineId.map { "{\"machineId\":\"\($0)\"}" } ?? "{\"machineId\":null}"
            return try await client.send(
                .post,
                headers: creatorHeaders,
                to: URI(string: "/api/agents/\(fixture.agentId)/assign-machine")
            ) { request in
                request.body = .init(string: body)
            }
        }
        for machineId in [fixture.targetMachineId, nil] {
            let refused = try await assign(machineId)
            #expect(refused.status == .conflict)
            #expect(agentsGapObject(refused)["code"] as? String == "MIGRATION_ALREADY_IN_PROGRESS")
            #expect(fixture.accounts.agentMachineIdForTesting(agentId: fixture.agentId) == fixture.machineId)
        }
        fixture.accounts.setMachineMigrationStateForTesting(migrationRef: ref, state: "aborted")
        let assigned = try await assign(fixture.targetMachineId)
        #expect(assigned.status == .ok)
        #expect(fixture.accounts.agentMachineIdForTesting(agentId: fixture.agentId) == fixture.targetMachineId)
        let unassigned = try await assign(nil)
        #expect(unassigned.status == .ok)
        #expect(fixture.accounts.agentMachineIdForTesting(agentId: fixture.agentId) == nil)
    }
}

// MARK: - Onboarding Cindy (upstream 4048, 4099, 4127)

@Test func agentOnboardingCindyCreatesAdminAgentAndRefusesDuplicates() async throws {
    let fixture = makeAgentsGapFixture(5208)
    try await withAgentsGapApp(fixture) { client, ownerHeaders, _, _ in
        var createHeaders = ownerHeaders
        createHeaders[.contentType] = "application/json"
        let created = try await client.send(.post, headers: createHeaders, to: "/api/agents") { request in
            request.body = .init(string: """
            {"name":"Custom Guide","description":"Custom onboarding guide","avatarUrl":"pixel:finch","runtime":"codex","onboarding":true}
            """)
        }
        #expect(created.status == .ok)
        let body = agentsGapObject(created)
        #expect(body["name"] as? String == "Cindy")
        #expect(body["displayName"] as? String == "Cindy")
        #expect(body["description"] as? String == "Onboarding Assistant")
        #expect(body["avatarUrl"] as? String == "pixel:mug")
        #expect(body["serverRole"] as? String == "admin")
        let runtimeConfig = body["runtimeConfig"] as? [String: Any]
        let envVars = runtimeConfig?["envVars"] as? [String: Any]
        #expect(envVars?["SLOCK_ONBOARDING_MEMORY_SEED"] as? String == "first-cindy")
        let onboardingAgentId = try #require(body["id"] as? String)

        let duplicate = try await client.send(.post, headers: createHeaders, to: "/api/agents") { request in
            request.body = .init(string: "{\"name\":\"Cindy\",\"description\":\"Onboarding Assistant\",\"runtime\":\"codex\",\"onboarding\":true}")
        }
        #expect(duplicate.status == .conflict)
        #expect(agentsGapObject(duplicate)["onboardingAgentId"] as? String == onboardingAgentId)
        let unchanged = try await client.get(URI(string: "/api/agents/\(onboardingAgentId)"), headers: ownerHeaders)
        #expect(agentsGapObject(unchanged)["name"] as? String == "Cindy")

        // A normally created agent named Cindy blocks the onboarding create.
        let fixture2 = makeAgentsGapFixture(5209)
        try await withAgentsGapApp(fixture2) { client2, ownerHeaders2, _, _ in
            var headers2 = ownerHeaders2
            headers2[.contentType] = "application/json"
            let normal = try await client2.send(.post, headers: headers2, to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"Cindy\",\"description\":\"Onboarding Assistant\",\"runtime\":\"codex\"}")
            }
            #expect(normal.status == .ok)
            let cindyDuplicate = try await client2.send(.post, headers: headers2, to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"Cindy\",\"description\":\"Onboarding Assistant\",\"runtime\":\"codex\",\"onboarding\":true}")
            }
            #expect(cindyDuplicate.status == .conflict)
            #expect((agentsGapObject(cindyDuplicate)["error"] as? String ?? "").contains("Cindy agent already exists"))
        }

        // An existing onboarding agent is never overwritten.
        let fixture3 = makeAgentsGapFixture(5210)
        let customized = fixture3.accounts.oauth.createAgent(
            serverId: fixture3.serverId,
            name: "SetupGuide",
            description: "Custom setup guide",
            creatorUserId: fixture3.ownerId,
            runtime: "codex"
        )
        fixture3.accounts.setServerOnboardingAgentForTesting(serverId: fixture3.serverId, agentId: customized)
        try await withAgentsGapApp(fixture3) { client3, ownerHeaders3, _, _ in
            var headers3 = ownerHeaders3
            headers3[.contentType] = "application/json"
            let blocked = try await client3.send(.post, headers: headers3, to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"Cindy\",\"description\":\"Onboarding Assistant\",\"runtime\":\"codex\",\"onboarding\":true}")
            }
            #expect(blocked.status == .conflict)
            let blockedBody = agentsGapObject(blocked)
            #expect((blockedBody["error"] as? String ?? "").contains("Onboarding agent already exists"))
            #expect(blockedBody["onboardingAgentId"] as? String == customized)
            let view = try await client3.get(URI(string: "/api/agents/\(customized)"), headers: ownerHeaders3)
            #expect(agentsGapObject(view)["name"] as? String == "SetupGuide")
        }
    }
}

// MARK: - v2 protocol field-pointing (upstream 6804)

@Test func agentCreateV2MalformedProviderConnectionIdIsRejected() async throws {
    let fixture = makeAgentsGapFixture(5211)
    try await withAgentsGapApp(fixture) { client, _, creatorHeaders, _ in
        func create(_ providerId: String) async throws -> ClientResponse {
            let body = """
            {"name":"v2-\(UUID().uuidString.prefix(6))","formDefinitionRef":{"protocolVersion":2,"runtimeId":"builtin"},"formValues":{"providerId":"\(providerId)","model":"deepseek/deepseek-v4-pro"}}
            """
            return try await client.send(.post, headers: creatorHeaders, to: "/api/agents") { request in
                request.body = .init(string: body)
            }
        }
        let malformed = try await create("connection:not-a-uuid")
        #expect(malformed.status == .badRequest)
        let absent = try await create("connection:11111111-1111-4111-8111-111111111111")
        #expect(absent.status == .conflict)
    }
}

private final class AgentsGapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var events: [String] = []

    func increment(_ key: String) {
        lock.lock()
        counts[key, default: 0] += 1
        lock.unlock()
    }

    func count(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key] ?? 0
    }

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        events.removeAll()
        counts.removeAll()
        lock.unlock()
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

// MARK: - Built-in preset catalog scope matrix (upstream 1228, 1338, 1451, 1499, 1549, 1674, 1730)

private func agentsGapBuiltinConfig(_ modelId: String) -> String {
    """
    {"version":1,"runtime":"builtin","provider":{"kind":"preset","providerId":"openai","apiKey":"secret"},"model":{"kind":"preset","id":"\(modelId)"},"mode":{"kind":"default"}}
    """
}

@Test func agentBuiltinPresetCreateAssignAndChangeRespectTheCatalog() async throws {
    let fixture = makeAgentsGapFixture(5301)
    fixture.accounts.machineMigrationCapabilities[fixture.machineId] = ["migration/v3"]
    fixture.accounts.setMachineRuntimesForTesting(machineId: fixture.machineId, runtimes: ["builtin"])
    let recorder = AgentsGapRecorder()
    try await withAgentsGapApp(fixture) { client, _, creatorHeaders, _ in
        func create(_ name: String, machineId: String?, model: String) async throws -> ClientResponse {
            let machineJSON = machineId.map { ",\"machineId\":\"\($0)\"" } ?? ""
            let body = """
            {"name":"\(name)","runtimeConfig":\(agentsGapBuiltinConfig(model))\(machineJSON)}
            """
            return try await client.send(.post, headers: creatorHeaders, to: "/api/agents") { request in
                request.body = .init(string: body)
            }
        }

        // Catalog says the model is absent: the write still persists (task #322).
        fixture.accounts.builtinModelCatalogCheck = { _, _ in
            recorder.increment("catalog")
            return .modelAbsent
        }
        let persisted = try await create("builtin-create-\(5301)", machineId: fixture.machineId, model: "openai/gpt-5.4")
        #expect(persisted.status == .ok)
        #expect(recorder.count("catalog") == 1)
        let createdBody = agentsGapObject(persisted)
        let createdId = try #require(createdBody["id"] as? String)
        #expect(createdBody["model"] as? String == "openai/gpt-5.4")

        // The catalog cannot be read: reject and create nothing.
        fixture.accounts.builtinModelCatalogCheck = { _, _ in .catalogUnavailable }
        let before = fixture.accounts.oauth.serverAgents(serverId: fixture.serverId).count
        let rejected = try await create("builtin-create-unavailable-\(5301)", machineId: fixture.machineId, model: "openai/gpt-5.4")
        #expect(rejected.status == .conflict)
        #expect(agentsGapObject(rejected)["code"] as? String == "builtin_catalog_unavailable")
        #expect(fixture.accounts.oauth.serverAgents(serverId: fixture.serverId).count == before)

        // assign-machine: catalog absence still assigns; unreadable catalog refuses.
        let unassignedAgent = try #require(agentsGapObject(try await create("builtin-assign-\(5301)", machineId: nil, model: "openai/gpt-5.4"))["id"] as? String)
        let assign = { (machineId: String) async throws -> ClientResponse in
            try await client.send(.post, headers: creatorHeaders, to: URI(string: "/api/agents/\(unassignedAgent)/assign-machine")) { request in
                request.body = .init(string: "{\"machineId\":\"\(machineId)\"}")
            }
        }
        fixture.accounts.builtinModelCatalogCheck = { _, _ in .catalogUnavailable }
        let refusedAssign = try await assign(fixture.machineId)
        #expect(refusedAssign.status == .conflict)
        #expect(agentsGapObject(refusedAssign)["code"] as? String == "builtin_catalog_unavailable")
        #expect(fixture.accounts.agentMachineIdForTesting(agentId: unassignedAgent) == nil)
        fixture.accounts.builtinModelCatalogCheck = { _, _ in .modelAbsent }
        let acceptedAssign = try await assign(fixture.machineId)
        #expect(acceptedAssign.status == .ok)
        #expect(fixture.accounts.agentMachineIdForTesting(agentId: unassignedAgent) == fixture.machineId)

        // PATCH model change: absence persists; unreadable catalog refuses with no write.
        let patch = { (model: String) async throws -> ClientResponse in
            try await client.send(.patch, headers: creatorHeaders, to: URI(string: "/api/agents/\(createdId)")) { request in
                request.body = .init(string: "{\"model\":\"\(model)\"}")
            }
        }
        fixture.accounts.builtinModelCatalogCheck = { _, _ in .catalogUnavailable }
        let refusedPatch = try await patch("openai/gpt-5.5")
        #expect(refusedPatch.status == .conflict)
        #expect(agentsGapObject(refusedPatch)["code"] as? String == "builtin_catalog_unavailable")
        let unchanged = try await client.get(URI(string: "/api/agents/\(createdId)"), headers: creatorHeaders)
        #expect(agentsGapObject(unchanged)["model"] as? String == "openai/gpt-5.4")
        fixture.accounts.builtinModelCatalogCheck = { _, _ in .modelAbsent }
        let acceptedPatch = try await patch("openai/gpt-5.5")
        #expect(acceptedPatch.status == .ok)
        let updated = try await client.get(URI(string: "/api/agents/\(createdId)"), headers: creatorHeaders)
        #expect(agentsGapObject(updated)["model"] as? String == "openai/gpt-5.5")
    }
}

@Test func agentBuiltinPresetMigrateRespectsTheCatalog() async throws {
    let fixture = makeAgentsGapFixture(5302)
    fixture.accounts.enableAgentMigrationForTesting(serverId: fixture.serverId)
    fixture.accounts.setMachineRuntimesForTesting(machineId: fixture.machineId, runtimes: ["builtin"])
    fixture.accounts.setMachineRuntimesForTesting(machineId: fixture.targetMachineId, runtimes: ["builtin"])
    fixture.accounts.machineMigrationCapabilities[fixture.machineId] = ["migration/v3"]
    fixture.accounts.machineMigrationCapabilities[fixture.targetMachineId] = ["migration/v3"]
    let agent = fixture.accounts.oauth.createAgent(
        serverId: fixture.serverId,
        name: "builtin-migrate-\(5302)",
        creatorUserId: fixture.creatorId,
        runtime: "builtin",
        runtimeConfigJSON: agentsGapBuiltinConfig("openai/gpt-5.4")
    )
    fixture.accounts.setAgentMachineForTesting(agentId: agent, machineId: fixture.machineId)
    fixture.accounts.machineMigrationProvisioner = { _, _ in "session-builtin-\(5302)" }
    try await withAgentsGapApp(fixture) { client, _, creatorHeaders, _ in
        fixture.accounts.builtinModelCatalogCheck = { _, _ in .catalogUnavailable }
        let refused = try await client.send(.post, headers: creatorHeaders, to: URI(string: "/api/agents/\(agent)/migrate")) { request in
            request.body = .init(string: "{\"targetComputer\":\"\(fixture.targetMachineId)\"}")
        }
        #expect(refused.status == .conflict)
        #expect(agentsGapObject(refused)["code"] as? String == "builtin_catalog_unavailable")

        fixture.accounts.builtinModelCatalogCheck = { _, _ in .modelAbsent }
        let enqueued = try await client.send(.post, headers: creatorHeaders, to: URI(string: "/api/agents/\(agent)/migrate")) { request in
            request.body = .init(string: "{\"targetComputer\":\"\(fixture.targetMachineId)\"}")
        }
        #expect(enqueued.status == .ok)
        let enqueuedBody = agentsGapObject(enqueued)
        let ref = try #require(enqueuedBody["migrationRef"] as? String)
        let snapshot = try #require(fixture.accounts.machineMigrationStateForTesting(migrationRef: ref))
        #expect(snapshot.state == "provisioning")
    }
}

@Test func agentV2CreatePointsModelIssueAtTheSubmittedField() async throws {
    let fixture = makeAgentsGapFixture(5303)
    fixture.accounts.setMachineRuntimesForTesting(machineId: fixture.machineId, runtimes: ["kimi-sdk"])
    fixture.accounts.agentRuntimeModelsForMachine = { _, _ in ["kimi-code/k3"] }
    try await withAgentsGapApp(fixture) { client, _, creatorHeaders, _ in
        let response = try await client.send(.post, headers: creatorHeaders, to: "/api/agents") { request in
            request.body = .init(string: """
            {"name":"V2Kimi","runtime":"kimi-sdk","machineId":"\(fixture.machineId)","formDefinitionRef":{"protocolVersion":2,"runtimeId":"kimi-sdk"},"formValues":{"model":"kimi-code/not-on-this-computer"}}
            """)
        }
        #expect(response.status.code >= 400)
        let body = agentsGapObject(response)
        let issues = body["issues"] as? [[String: Any]] ?? []
        #expect(!issues.isEmpty)
        #expect(issues.allSatisfy { $0["pointer"] as? String == "/formValues/model" })
    }
}
