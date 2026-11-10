import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Published contracts used together by the pinned Web. Store setup establishes
/// actual persisted facts; it does not qualify a live CLI or a model launch.
private struct OnboardingContractFixture {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased()
    let guest = UUID().uuidString.lowercased()
    let admin = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()

    init() {
        for (id, label) in [(owner, "owner"), (guest, "guest"), (admin, "admin")] {
            accounts.addAccount(id: id, email: "contract-\(label)-\(id)@example.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: server, slug: "contract-\(server)", name: "Contract", ownerId: owner)
        accounts.oauth.addMember(serverId: server, userId: guest, role: "guest")
        accounts.oauth.addMember(serverId: server, userId: admin, role: "admin")
    }

    func headers(_ user: String, marker: Bool = false) -> HTTPFields {
        var fields = HTTPFields()
        fields[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: user))"
        fields[.contentType] = "application/json"
        fields[HTTPField.Name("X-Server-Id")!] = server
        if marker { fields[HTTPField.Name("X-Raft-Runtime-Form-V2")!] = "1" }
        return fields
    }
}

private func onboardingObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
}

private func onboardingRows(_ response: ClientResponse) throws -> [[String: Any]] {
    try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]])
}

@Test func onboardingAgentCreateListDetailAndAdmissionKeepTheAssignedComputer() async throws {
    let f = OnboardingContractFixture()
    let machine = f.accounts.registerMachine(serverId: f.server, userId: f.owner, name: "Retained computer")
    f.accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: ["codex", "grok", "builtin", "kimi-sdk", "copilot"])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let created = try await client.send(.post, headers: f.headers(f.owner), to: "/api/agents") { request in
                request.body = .init(string: """
                {"name":"Cindy","onboarding":true,"machineId":"\(machine)","runtime":"codex","model":"contract-model","runtimeConfig":{"version":1,"runtime":"codex","model":{"kind":"custom","name":"contract-model"},"reasoningEffort":"high"}}
                """)
            }
            #expect(created.status == .ok)
            let initial = try onboardingObject(created)
            let agent = try #require(initial["id"] as? String)
            #expect(initial["machineId"] as? String == machine)
            #expect(initial["serverId"] as? String == f.server)
            #expect(initial["status"] as? String == "inactive")
            #expect(initial["reasoningEffort"] as? String == "high")
            // Preserve the actual stored status vocabulary: active is NOT running.
            f.accounts.oauth.setAgentStatus(id: agent, status: "active")
            for response in [
                try await client.get(URI(string: "/api/agents/\(agent)"), headers: f.headers(f.owner)),
                try await client.get("/api/agents", headers: f.headers(f.owner)),
            ] {
                #expect(response.status == .ok)
                let row: [String: Any]
                if response.body.string?.first == "[" {
                    row = try #require(try onboardingRows(response).first { $0["id"] as? String == agent })
                } else { row = try onboardingObject(response) }
                #expect(row["machineId"] as? String == machine)
                #expect(row["serverId"] as? String == f.server)
                #expect(row["status"] as? String == "active")
                #expect(row["avatarUrl"] as? String == "pixel:mug")
                #expect(row["reasoningEffort"] as? String == "high")
                #expect(row["createdAt"] == nil, "unknown historical time is not manufactured")
            }
            let existing = try await client.get(URI(string: "/api/agents/\(agent)/runtime-options"), headers: f.headers(f.owner, marker: true))
            let catalog = try onboardingObject(existing)
            #expect(catalog["context"] as? String == "existing_agent")
            #expect(catalog["machineId"] as? String == machine)
            #expect(catalog["runtimes"] == nil && catalog["models"] == nil)
            let options = try #require(catalog["options"] as? [[String: Any]])
            let codex = try #require(options.first { $0["runtimeId"] as? String == "codex" })
            #expect(codex["current"] as? Bool == true)
            #expect(codex["manageableForCurrentAgent"] as? Bool == true)
            #expect(codex["canSelectInThisContext"] as? Bool == true)
            #expect(!options.contains { $0["runtimeId"] as? String == "grok" })
        }
    }
}

@Test func onboardingAdmissionKeepsV1RefsIndependentFromV2AndGrandfathersCurrentRuntime() async throws {
    let f = OnboardingContractFixture()
    let machine = f.accounts.registerMachine(serverId: f.server, userId: f.owner, name: "Inventory")
    f.accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: ["claude", "codex", "grok", "builtin", "kimi-sdk", "cursor", "copilot"])
    let grok = f.accounts.oauth.createAgent(serverId: f.server, name: "existing-grok", creatorUserId: f.owner, runtime: "grok")
    let legacy = f.accounts.oauth.createAgent(serverId: f.server, name: "existing-copilot", creatorUserId: f.owner, runtime: "copilot")
    f.accounts.agentsRuntimeStore.bindMachine(agentId: grok, machineId: machine)
    f.accounts.agentsRuntimeStore.bindMachine(agentId: legacy, machineId: machine)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let base = "/api/servers/\(f.server)/machines/\(machine)"
            for marker in [false, true] {
                let reply = try await client.get(URI(string: "\(base)/runtime-options"), headers: f.headers(f.owner, marker: marker))
                let options = try #require(try onboardingObject(reply)["options"] as? [[String: Any]])
                if marker {
                    // The newly reachable combined row preserves pinned Node key order.
                    #expect(reply.body.string?.contains("\"formDefinitionRef\":{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\"builtin-pi.create.v3\"},\"runtimeFormV2\":{\"protocolVersion\":2}") == true)
                }
                for id in ["builtin", "kimi-sdk"] {
                    let row = try #require(options.first { $0["runtimeId"] as? String == id })
                    let ref = try #require(row["formDefinitionRef"] as? [String: Any])
                    #expect(ref["protocolVersion"] as? Int == 1)
                    #expect(ref["runtimeId"] as? String == id)
                    #expect((row["runtimeFormV2"] != nil) == marker)
                }
                for id in ["claude", "cursor", "codex"] {
                    let row = try #require(options.first { $0["runtimeId"] as? String == id })
                    #expect(row["formDefinitionRef"] == nil)
                }
                #expect(!options.contains { ["grok", "copilot"].contains($0["runtimeId"] as? String ?? "") })
            }
            for (agent, runtime, reason) in [(grok, "grok", "feature_flag_off"), (legacy, "copilot", "deprecated")] {
                let reply = try await client.get(URI(string: "/api/agents/\(agent)/runtime-options"), headers: f.headers(f.owner, marker: true))
                let options = try #require(try onboardingObject(reply)["options"] as? [[String: Any]])
                let current = try #require(options.first { $0["runtimeId"] as? String == runtime })
                #expect(current["admissionStatus"] as? String == "grandfathered_current")
                #expect(current["admissionReason"] as? String == reason)
                #expect(current["current"] as? Bool == true)
                #expect(current["availableForNew"] as? Bool == false)
                #expect(current["manageableForCurrentAgent"] as? Bool == true)
                #expect(current["canSelectInThisContext"] as? Bool == true)
            }
            for runtime in ["claude", "cursor", "codex"] {
                let response = try await client.get(URI(string: "\(base)/runtime-form-definitions/\(runtime)?schemaVersion=\(runtime).create.v1"), headers: f.headers(f.owner))
                #expect(response.status == .notFound)
            }
        }
    }
}

@Test func onboardingRuntimeMarkersMatchTheEightActuallyServedV2Registrations() async throws {
    let f = OnboardingContractFixture()
    f.accounts.createFeatureFlagForTesting(key: "grok_runtime_v0", defaultEnabled: true)
    let registered = Set(["builtin", "claude", "codex", "grok", "kimi-sdk", "cursor", "opencode", "pi"])
    let machine = f.accounts.registerMachine(serverId: f.server, userId: f.owner, name: "Real registered metadata")
    f.accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: registered.sorted())
    let agent = f.accounts.oauth.createAgent(serverId: f.server, name: "current-codex", creatorUserId: f.owner, runtime: "codex")
    f.accounts.agentsRuntimeStore.bindMachine(agentId: agent, machineId: machine)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let machineBase = "/api/servers/\(f.server)/machines/\(machine)"
            let catalogs = ["\(machineBase)/runtime-options", "/api/agents/\(agent)/runtime-options"]
            let markers: [String?] = [nil, "0", "true", "2", "1"]
            for marker in markers {
                var headers = f.headers(f.owner)
                headers[HTTPField.Name("X-Raft-Runtime-Form-V2")!] = marker
                for path in catalogs {
                    let reply = try await client.get(URI(string: path), headers: headers)
                    #expect(reply.status == .ok)
                    let rows = try #require(try onboardingObject(reply)["options"] as? [[String: Any]])
                    #expect(Set(rows.compactMap { $0["runtimeId"] as? String }) == registered)
                    for row in rows {
                        let runtime = try #require(row["runtimeId"] as? String)
                        #expect((row["formDefinitionRef"] != nil) == ["builtin", "kimi-sdk"].contains(runtime))
                        if marker == "1" {
                            let v2 = try #require(row["runtimeFormV2"] as? [String: Any])
                            #expect(v2["protocolVersion"] as? Int == 2)
                        } else {
                            #expect(row["runtimeFormV2"] == nil)
                        }
                    }
                }
            }
            // Every advertised registration has a real served definition.
            for runtime in registered.sorted() {
                let reply = try await client.get(URI(string: "\(machineBase)/runtime-forms/v2/\(runtime)"), headers: f.headers(f.owner))
                #expect(reply.status == .ok)
                let definition = try onboardingObject(reply)
                #expect(definition["runtimeId"] as? String == runtime)
                #expect(definition["protocolVersion"] as? Int == 2)
                #expect((definition["schemaVersion"] as? String)?.isEmpty == false)
                #expect(definition["dataSchema"] is [String: Any])
            }
        }
    }
}

@Test func guestAgentDirectoryUsesReadableLocalRelationsAndARealAllChannel() async throws {
    let f = OnboardingContractFixture()
    f.accounts.createFeatureFlagForTesting(key: "server_guest_v0", defaultEnabled: true)
    let all = try #require(f.accounts.oauth.allChannelId(serverId: f.server))
    f.accounts.addPostableChannel(serverId: f.server, channelId: all, memberId: f.owner, name: "all")
    f.accounts.setChannelGuestVisibleForTesting(channelId: all, visible: false)
    // A stale all membership must not reveal all agents when all is hidden.
    f.accounts.oauth.addChannelHuman(channelId: all, userId: f.guest)
    let visible = f.accounts.oauth.createChannel(serverId: f.server, name: "readable", creatorUserId: f.owner)
    f.accounts.addPostableChannel(serverId: f.server, channelId: visible, memberId: f.owner, name: "readable")
    f.accounts.setChannelGuestVisibleForTesting(channelId: visible, visible: true)
    f.accounts.oauth.setChannelArchived(id: visible, archivedAt: Date())
    let shown = f.accounts.oauth.createAgent(serverId: f.server, name: "shown-agent", description: "Public role", creatorUserId: f.owner)
    let hidden = f.accounts.oauth.createAgent(serverId: f.server, name: "hidden-agent", creatorUserId: f.owner)
    f.accounts.oauth.addChannelAgent(channelId: visible, agentId: shown)
    // A readable DM is not one of Node listChannels' profile-granting kinds.
    let dm = f.accounts.oauth.createDirectChannel(serverId: f.server, firstUserId: f.guest, secondUserId: hidden)
    f.accounts.oauth.addChannelAgent(channelId: dm, agentId: hidden)
    f.accounts.serversAndChannelsStore.upsertDirectChannel(serverId: f.server, channelId: dm, memberIds: [f.guest, hidden])
    let foreignServer = UUID().uuidString.lowercased()
    f.accounts.oauth.addOwnedServer(id: foreignServer, slug: "foreign-\(foreignServer)", name: "Foreign", ownerId: f.owner)
    let foreign = f.accounts.oauth.createAgent(serverId: foreignServer, name: "foreign-agent", creatorUserId: f.owner)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let listed = try await client.get("/api/agents", headers: f.headers(f.guest))
            #expect(listed.status == .ok)
            let rows = try onboardingRows(listed)
            #expect(rows.compactMap { $0["id"] as? String } == [shown])
            let detail = try await client.get(URI(string: "/api/agents/\(shown)"), headers: f.headers(f.guest))
            #expect(detail.status == .ok)
            let publicRow = try onboardingObject(detail)
            #expect(publicRow["profileProjection"] as? String == "channel_summary")
            #expect(publicRow["serverId"] as? String == f.server)
            #expect(publicRow["description"] as? String == "Public role")
            #expect(publicRow["activityDetail"] as? String == "")
            let privateOptions = try await client.get(URI(string: "/api/agents/\(shown)/runtime-options"), headers: f.headers(f.guest))
            #expect(privateOptions.status == .forbidden)
            #expect(privateOptions.body.string == "{\"error\":\"The `viewAgents` capability is required to inspect runtime options\"}")
            for row in rows + [publicRow] {
                for key in ["runtime", "model", "runtimeConfig", "envVars", "machineId", "creator", "serverRole"] { #expect(row[key] == nil) }
            }
            for id in [hidden, foreign] {
                let denied = try await client.get(URI(string: "/api/agents/\(id)"), headers: f.headers(f.guest))
                #expect(denied.status == .notFound)
                #expect(denied.body.string == "{\"error\":\"Agent not found\"}")
            }
            f.accounts.setChannelGuestVisibleForTesting(channelId: all, visible: true)
            let allVisible = try await client.get("/api/agents", headers: f.headers(f.guest))
            #expect(Set(try onboardingRows(allVisible).compactMap { $0["id"] as? String }) == Set([shown, hidden]))
            // Disable the actual rollout: membership and visibility alone are insufficient.
            f.accounts.setFeatureFlagKillSwitchForTesting(key: "server_guest_v0", killSwitch: true)
            let disabled = try await client.get("/api/agents", headers: f.headers(f.guest))
            #expect(try onboardingRows(disabled).isEmpty)
            f.accounts.oauth.removeMember(serverId: f.server, userId: f.guest)
            let removed = try await client.get("/api/agents", headers: f.headers(f.guest))
            #expect(removed.status == .forbidden)
            #expect(removed.body.string == "{\"error\":\"Not a member of this server\"}")
        }
    }
}
