import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private enum GrokPolicyScenario: CaseIterable, Equatable, Sendable {
    case defaultOn, serverAllow, userAllow, userDeny, killSwitch, disabled, missing, serverDeny, contextualOnly

    var legacySet: Bool {
        switch self {
        case .defaultOn, .serverAllow, .userAllow: false
        default: true
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .defaultOn, .userDeny, .killSwitch, .disabled, .serverDeny: true
        default: false
        }
    }

    func expected(owner: Bool, primaryServer: Bool) -> (enabled: Bool, reason: String) {
        switch self {
        case .defaultOn: (true, "default")
        case .serverAllow: (primaryServer, primaryServer ? "server_rule" : "default")
        case .userAllow: (owner, owner ? "user_rule" : "default")
        case .userDeny: (!owner, owner ? "user_rule" : (primaryServer ? "server_rule" : "default"))
        case .killSwitch: (false, "kill_switch")
        case .disabled: (false, "flag_disabled")
        case .missing: (false, "missing_flag")
        case .serverDeny: (!primaryServer, primaryServer ? "server_rule" : "default")
        case .contextualOnly: (false, "default")
        }
    }
}

/// These are actual retained flag rows/rules and member/inventory facts. The
/// legacy set deliberately disagrees. No fixture marks a Computer online or
/// claims an installed CLI, provider run, start ACK or live model execution.
private struct GrokPolicyFixture {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased()
    let admin = UUID().uuidString.lowercased()
    let primary = UUID().uuidString.lowercased()
    let secondary = UUID().uuidString.lowercased()
    var machines: [String: String] = [:]
    var agents: [String: (codex: String, grok: String)] = [:]

    init(_ scenario: GrokPolicyScenario) {
        for user in [owner, admin] {
            accounts.addAccount(id: user, email: "grok-policy-\(user)@example.test", password: "password123")
            accounts.markEmailVerified(userId: user)
        }
        for server in [primary, secondary] {
            accounts.oauth.addOwnedServer(id: server, slug: "grok-policy-\(server)", name: "Policy", ownerId: owner)
            accounts.oauth.addMember(serverId: server, userId: admin, role: "admin")
            let machine = accounts.registerMachine(serverId: server, userId: owner, name: "Retained inventory")
            accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: ["codex", "grok"])
            machines[server] = machine
            let codex = accounts.oauth.createAgent(serverId: server, name: "policy-codex", creatorUserId: owner, runtime: "codex")
            let grok = accounts.oauth.createAgent(serverId: server, name: "policy-current-grok", creatorUserId: owner, runtime: "grok")
            accounts.agentsRuntimeStore.bindMachine(agentId: codex, machineId: machine)
            accounts.agentsRuntimeStore.bindMachine(agentId: grok, machineId: machine)
            agents[server] = (codex, grok)
            // Explicit contradiction proves this legacy test seam is not policy.
            accounts.enableGrokRuntimeForTesting(serverId: server, enabled: scenario.legacySet)
        }
        accounts.agentsRuntimeStore.withState { state in
            state.featureFlagRecords.removeValue(forKey: "grok_runtime_v0")
            state.featureFlagRuleRecords.removeAll { $0.key == "grok_runtime_v0" }
        }
        if scenario != .missing {
            accounts.createFeatureFlagForTesting(key: "grok_runtime_v0", defaultEnabled: scenario.defaultEnabled,
                enabled: scenario != .disabled, killSwitch: scenario == .killSwitch)
        }
        switch scenario {
        case .serverAllow:
            accounts.addFeatureFlagRuleForTesting(key: "grok_runtime_v0", stage: "server", decision: "allow", values: [primary])
        case .userAllow:
            accounts.addFeatureFlagRuleForTesting(key: "grok_runtime_v0", stage: "user", decision: "allow", values: [owner])
        case .userDeny:
            accounts.addFeatureFlagRuleForTesting(key: "grok_runtime_v0", stage: "server", decision: "allow", values: [primary])
            accounts.addFeatureFlagRuleForTesting(key: "grok_runtime_v0", stage: "user", decision: "deny", values: [owner])
        case .killSwitch, .disabled:
            accounts.addFeatureFlagRuleForTesting(key: "grok_runtime_v0", stage: "user", decision: "allow", values: [owner])
            accounts.addFeatureFlagRuleForTesting(key: "grok_runtime_v0", stage: "server", decision: "allow", values: [primary])
        case .serverDeny:
            accounts.addFeatureFlagRuleForTesting(key: "grok_runtime_v0", stage: "server", decision: "deny", values: [primary])
        case .contextualOnly:
            accounts.addFeatureFlagRuleForTesting(key: "grok_runtime_v0", stage: "platform", decision: "allow", values: ["web"])
            accounts.addFeatureFlagRuleForTesting(key: "grok_runtime_v0", stage: "client", decision: "allow", values: [primary],
                clientOs: ["android"], minClientBuild: 1)
        default: break
        }
    }

    func headers(user: String, server: String) -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: user))"
        headers[.contentType] = "application/json"
        headers[HTTPField.Name("X-Server-Id")!] = server
        headers[HTTPField.Name("X-Raft-Runtime-Form-V2")!] = "1"
        return headers
    }
}

private func grokPolicyObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
}

@Test func grokWritesValidateMachineScopeBeforePolicyAndInventoryAfterPolicy() async throws {
    let grok = "{\"version\":1,\"runtime\":\"grok\",\"model\":{\"kind\":\"custom\",\"name\":\"protocol-only-model\"}}"
    let codex = "{\"version\":1,\"runtime\":\"codex\",\"model\":{\"kind\":\"custom\",\"name\":\"protocol-only-model\"}}"
    let flagWire = "{\"error\":\"Grok Build is not enabled on this server\",\"code\":\"grok_runtime_disabled\"}"
    let capWire = "{\"error\":\"Grok Build is not available on this computer\",\"code\":\"runtime_capability_unavailable\"}"
    for scenario in [GrokPolicyScenario.defaultOn, .missing, .killSwitch, .userDeny] {
        let f = GrokPolicyFixture(scenario)
        let local = try #require(f.machines[f.primary])
        let foreign = try #require(f.machines[f.secondary])
        let current = try #require(f.agents[f.primary]).grok
        let enabled = scenario.expected(owner: true, primaryServer: true).enabled
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
            try await app.testing { client in
                let h = f.headers(user: f.owner, server: f.primary)
                func post(_ members: String) async throws -> ClientResponse {
                    try await client.send(.post, headers: h, to: "/api/agents") { request in
                        request.body = .init(string: "{\"name\":\"machine-\(UUID().uuidString.prefix(8))\",\(members)}")
                    }
                }
                func ids() async throws -> Set<String> {
                    let response = try await client.get("/api/agents", headers: h)
                    #expect(response.status == .ok)
                    let rows = try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]])
                    return Set(rows.compactMap { $0["id"] as? String })
                }
                for shape in ["\"runtimeConfig\":\(grok)", "\"runtime\":\"grok\""] {
                    for bad in [UUID().uuidString.lowercased(), foreign] {
                        let before = try await ids()
                        let refused = try await post("\(shape),\"machineId\":\"\(bad)\"")
                        #expect(refused.status == .badRequest)
                        #expect(refused.body.string == "{\"error\":\"Machine not found in this server\"}")
                        #expect(try await ids() == before)
                    }
                    for malformed in ["\"not-a-uuid\"", "17", "true", "{}", "[]"] {
                        let before = try await ids()
                        let refused = try await post("\(shape),\"machineId\":\(malformed)")
                        #expect(refused.status == .badRequest)
                        #expect(refused.body.string == "{\"error\":\"Invalid machineId: must be a UUID\"}")
                        #expect(try await ids() == before)
                    }
                    let accepted = try await post("\(shape),\"machineId\":\"\(local.uppercased())\"")
                    #expect(accepted.status == (enabled ? .ok : .forbidden))
                    if enabled {
                        #expect(try grokPolicyObject(accepted)["runtime"] as? String == "grok")
                        #expect(try grokPolicyObject(accepted)["machineId"] as? String == local)
                    } else { #expect(accepted.body.string == flagWire) }
                    // Missing/null/empty/falsy machine is unassigned in Node.
                    // POST admission does not require installation without an assignment.
                    for absent in ["", ",\"machineId\":null", ",\"machineId\":\"\"", ",\"machineId\":false", ",\"machineId\":0"] {
                        let response = try await post(shape + absent)
                        #expect(response.status == (enabled ? .ok : .forbidden))
                        if enabled { #expect(try grokPolicyObject(response)["runtime"] as? String == "grok") }
                        else { #expect(response.body.string == flagWire) }
                    }
                }
                let precedence = try await post("\"runtime\":\"grok\",\"runtimeConfig\":\(codex)")
                #expect(precedence.status == .ok)
                #expect(try grokPolicyObject(precedence)["runtime"] as? String == "codex")
                let ignoredDeprecated = try await post("\"runtime\":\"kimi\",\"runtimeConfig\":\(codex)")
                #expect(ignoredDeprecated.status == .ok)
                #expect(try grokPolicyObject(ignoredDeprecated)["runtime"] as? String == "codex")
                let legacy = try await post("\"runtime\":\" grok \",\"model\":\"grok-4.6\",\"reasoningEffort\":\"high\",\"envVars\":{\"CUSTOM\":\"retained-input\"}")
                #expect(legacy.status == (enabled ? .ok : .forbidden))
                if enabled {
                    #expect(try grokPolicyObject(legacy)["runtime"] as? String == "grok")
                    #expect(try grokPolicyObject(legacy)["model"] as? String == "grok-4.6")
                    let defaultModel = try await post("\"runtime\":\"grok\"")
                    #expect(try grokPolicyObject(defaultModel)["model"] as? String == "grok-4.5")
                }
                let scalar = try await post("\"runtime\":\"grok\",\"runtimeConfig\":17")
                #expect(scalar.status == .badRequest)
                #expect(scalar.body.string == "{\"error\":\"runtimeConfig must be an object\"}")
                let envFirst = try await post("\"runtime\":\"grok\",\"machineId\":\"\(foreign)\",\"envVars\":17")
                #expect(envFirst.body.string == "{\"error\":\"envVars must be an object\"}")
                let target = try await post("\"runtimeConfig\":\(codex),\"machineId\":\"\(local)\"")
                #expect(target.status == .ok)
                let targetId = try #require(try grokPolicyObject(target)["id"] as? String)
                let patchPriority = try await client.send(.patch, headers: h, to: "/api/agents/\(targetId)") { request in
                    request.body = .init(string: "{\"runtime\":\"kimi\",\"runtimeConfig\":\(codex)}")
                }
                #expect(patchPriority.status == .ok)
                // Actual retained inventory changes, without a fabricated online state.
                f.accounts.setMachineRuntimesForTesting(machineId: local, runtimes: ["codex"])
                let before = try await ids()
                let capPost = try await post("\"runtimeConfig\":\(grok),\"machineId\":\"\(local)\"")
                #expect(capPost.status == (enabled ? .conflict : .forbidden))
                #expect(capPost.body.string == (enabled ? capWire : flagWire))
                #expect(try await ids() == before)
                let legacyTarget = try #require(f.agents[f.primary]).codex
                let ignoredLegacy = try await client.send(.patch, headers: h, to: "/api/agents/\(targetId)") { request in
                    request.body = .init(string: "{\"runtime\":\"grok\"}")
                }
                #expect(ignoredLegacy.status == .ok)
                #expect(try grokPolicyObject(ignoredLegacy)["runtime"] as? String == "codex")
                for agent in [targetId, legacyTarget, current] {
                    let path = URI(string: "/api/agents/\(agent)")
                    let before = try await client.get(path, headers: h)
                    let updates = agent == targetId
                        ? ["\"runtimeConfig\":\(grok)", "\"runtimeConfig\":null,\"runtime\":\"grok\""]
                        : ["\"runtimeConfig\":\(grok)", "\"runtime\":\"grok\""]
                    for update in updates {
                        let refused = try await client.send(.patch, headers: h, to: "/api/agents/\(agent)") { request in
                            request.body = .init(string: "{\(update),\"description\":\"must-not-write\",\"displayName\":\"must-not-write\",\"serverRole\":\"admin\"}")
                        }
                        let capabilityWins = agent == current || enabled
                        #expect(refused.status == (capabilityWins ? .conflict : .forbidden))
                        #expect(refused.body.string == (capabilityWins ? capWire : flagWire))
                        let after = try await client.get(path, headers: h)
                        #expect(after.body.string == before.body.string)
                    }
                }
                // Current Grok does not gain a missing/foreign machine exemption.
                for missing in [UUID().uuidString.lowercased(), foreign] {
                    f.accounts.agentsRuntimeStore.bindMachine(agentId: current, machineId: missing)
                    let response = try await client.send(.patch, headers: h, to: "/api/agents/\(current)") { request in
                        request.body = .init(string: "{\"runtimeConfig\":\(grok)}")
                    }
                    #expect(response.status == .conflict)
                    #expect(response.body.string == capWire)
                }
                f.accounts.agentsRuntimeStore.withState { $0.agentMachineIds.removeValue(forKey: current) }
                let unassigned = try await client.send(.patch, headers: h, to: "/api/agents/\(current)") { request in
                    request.body = .init(string: "{\"runtimeConfig\":\(grok)}")
                }
                #expect(unassigned.body.string == capWire)
                let metadata = try await client.send(.patch, headers: h, to: "/api/agents/\(current)") { request in
                    request.body = .init(string: "{\"description\":\"metadata-only\"}")
                }
                #expect(metadata.status == .ok)
                f.accounts.agentsRuntimeStore.bindMachine(agentId: current, machineId: local)
                f.accounts.setMachineRuntimesForTesting(machineId: local, runtimes: ["codex", "grok"])
                let grandfather = try await client.send(.patch, headers: h, to: "/api/agents/\(current)") { request in
                    request.body = .init(string: "{\"runtimeConfig\":\(grok)}")
                }
                #expect(grandfather.status == .ok)
            }
        }
    }
}

@Test func grokDirectWritesUseActualPolicyAndKeepCurrentRuntimeGrandfathered() async throws {
    let deniedBody = "{\"error\":\"Grok Build is not enabled on this server\",\"code\":\"grok_runtime_disabled\"}"
    let grokConfig = "{\"version\":1,\"runtime\":\"grok\",\"model\":{\"kind\":\"custom\",\"name\":\"protocol-only-model\"}}"
    for scenario in GrokPolicyScenario.allCases {
        let f = GrokPolicyFixture(scenario)
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
            try await app.testing { client in
                for server in [f.primary, f.secondary] {
                    let machine = try #require(f.machines[server])
                    let pair = try #require(f.agents[server])
                    for user in [f.owner, f.admin] {
                        let headers = f.headers(user: user, server: server)
                        let allowed = scenario.expected(owner: user == f.owner, primaryServer: server == f.primary).enabled
                        let nonce = String(UUID().uuidString.prefix(8)).lowercased()
                        // A fresh Codex target per actor ensures every attempted
                        // switch is new use, rather than accidentally testing a
                        // previously grandfathered Grok from another iteration.
                        let target = try await client.send(.post, headers: headers, to: "/api/agents") { request in
                            request.body = .init(string: "{\"name\":\"flag-target-\(nonce)\",\"machineId\":\"\(machine)\",\"runtimeConfig\":{\"version\":1,\"runtime\":\"codex\",\"model\":{\"kind\":\"custom\",\"name\":\"protocol-only-model\"}}}")
                        }
                        #expect(target.status == .ok)
                        let targetId = try #require(try grokPolicyObject(target)["id"] as? String)
                        let targetPath = URI(string: "/api/agents/\(targetId)")
                        let beforeTarget = try await client.get(targetPath, headers: headers)
                        let beforeList = try await client.get("/api/agents", headers: headers)
                        let beforeRows = try #require(try JSONSerialization.jsonObject(with: Data((beforeList.body.string ?? "").utf8)) as? [[String: Any]])
                        let beforeIds = Set(beforeRows.compactMap { $0["id"] as? String })
                        let requestedName = "flag-write-\(nonce)"
                        let created = try await client.send(.post, headers: headers, to: "/api/agents") { request in
                            request.body = .init(string: "{\"name\":\"\(requestedName)\",\"machineId\":\"\(machine)\",\"runtimeConfig\":\(grokConfig)}")
                        }
                        if allowed {
                            #expect(created.status == .ok)
                            #expect(try grokPolicyObject(created)["runtime"] as? String == "grok")
                        } else {
                            #expect(created.status == .forbidden)
                            #expect(created.body.string == deniedBody)
                            let after = try await client.get("/api/agents", headers: headers)
                            let rows = try #require(try JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8)) as? [[String: Any]])
                            #expect(Set(rows.compactMap { $0["id"] as? String }) == beforeIds)
                            #expect(!rows.contains { $0["name"] as? String == requestedName })
                        }
                        let patched = try await client.send(.patch, headers: headers, to: "/api/agents/\(targetId)") { request in
                            // Metadata and role must not partially write before
                            // the runtime admission refusal.
                            request.body = .init(string: "{\"runtimeConfig\":\(grokConfig),\"description\":\"refused-\(nonce)\",\"displayName\":\"Changed\",\"serverRole\":\"admin\"}")
                        }
                        if allowed {
                            #expect(patched.status == .ok)
                            #expect(try grokPolicyObject(patched)["runtime"] as? String == "grok")
                        } else {
                            #expect(patched.status == .forbidden)
                            #expect(patched.body.string == deniedBody)
                            let after = try await client.get(targetPath, headers: headers)
                            #expect(after.status == .ok)
                            #expect(after.body.string == beforeTarget.body.string)
                        }
                        // The same flag may be disabled for this caller while an
                        // unchanged current Grok remains editable. No blanket ban.
                        let current = try await client.send(.patch, headers: headers, to: "/api/agents/\(pair.grok)") { request in
                            request.body = .init(string: "{\"runtimeConfig\":\(grokConfig),\"description\":\"current-\(nonce)\"}")
                        }
                        #expect(current.status == .ok)
                        #expect(try grokPolicyObject(current)["runtime"] as? String == "grok")
                        let metadata = try await client.send(.patch, headers: headers, to: "/api/agents/\(pair.codex)") { request in
                            request.body = .init(string: "{\"description\":\"metadata-\(nonce)\"}")
                        }
                        #expect(metadata.status == .ok)
                        if scenario == .missing, server == f.primary, user == f.owner {
                            let invalid = try await client.send(.post, headers: headers, to: "/api/agents") { request in
                                request.body = .init(string: "{\"name\":\"\",\"runtimeConfig\":\(grokConfig)}")
                            }
                            #expect(invalid.status == .badRequest)
                            #expect(invalid.body.string == "{\"error\":\"Invalid Agent\"}")
                            let restart = try await client.send(.patch, headers: headers, to: "/api/agents/\(targetId)") { request in
                                request.body = .init(string: "{\"runtimeConfig\":\(grokConfig),\"restartMode\":\"bad\"}")
                            }
                            #expect(restart.status == .badRequest)
                            #expect(restart.body.string == "{\"error\":\"Invalid restart mode: bad\"}")
                        }
                    }
                }
            }
        }
    }
}

@Test func grokAdmissionCatalogsUseTheActualCallerServerFlagPolicy() async throws {
    // Each case has fresh real retained facts. Both users may inspect both
    // servers, so differences can only come from caller/server flag authority.
    for scenario in GrokPolicyScenario.allCases {
        let f = GrokPolicyFixture(scenario)
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
            try await app.testing { client in
                for server in [f.primary, f.secondary] {
                    let machine = try #require(f.machines[server])
                    let pair = try #require(f.agents[server])
                    for user in [f.owner, f.admin] {
                        let headers = f.headers(user: user, server: server)
                        let expected = scenario.expected(owner: user == f.owner, primaryServer: server == f.primary)
                        let evaluation = try await client.send(.post, headers: headers, to: "/api/feature-flags/evaluate") { request in
                            // Node admission resolves only caller/server, without
                            // inventing a platform or passing optional client facts.
                            request.body = .init(string: "{\"key\":\"grok_runtime_v0\",\"serverId\":\"\(server)\"}")
                        }
                        #expect(evaluation.status == .ok)
                        let entries = try #require(try grokPolicyObject(evaluation)["evaluations"] as? [[String: Any]])
                        let result = try #require(entries.first)
                        #expect(result["key"] as? String == "grok_runtime_v0")
                        #expect(result["enabled"] as? Bool == expected.enabled)
                        #expect(result["reason"] as? String == expected.reason)

                        for path in [
                            "/api/servers/\(server)/machines/\(machine)/runtime-options",
                            "/api/agents/\(pair.codex)/runtime-options",
                        ] {
                            let response = try await client.get(URI(string: path), headers: headers)
                            #expect(response.status == .ok)
                            let rows = try #require(try grokPolicyObject(response)["options"] as? [[String: Any]])
                            let choice = rows.first { $0["runtimeId"] as? String == "grok" }
                            #expect((choice != nil) == expected.enabled)
                            if expected.enabled {
                                let row = try #require(choice)
                                #expect(row["admissionStatus"] as? String == "available_for_new")
                                #expect(row["admissionReason"] is NSNull)
                                #expect(row["availableForNew"] as? Bool == true)
                                #expect(row["current"] as? Bool == false)
                                #expect(row["canSelectInThisContext"] as? Bool == true)
                            }
                        }
                        let current = try await client.get(URI(string: "/api/agents/\(pair.grok)/runtime-options"), headers: headers)
                        #expect(current.status == .ok)
                        let currentRows = try #require(try grokPolicyObject(current)["options"] as? [[String: Any]])
                        let row = try #require(currentRows.first { $0["runtimeId"] as? String == "grok" })
                        #expect(row["current"] as? Bool == true)
                        #expect(row["capabilityStatus"] as? String == "available")
                        #expect(row["manageableForCurrentAgent"] as? Bool == true)
                        #expect(row["canSelectInThisContext"] as? Bool == true)
                        #expect(row["availableForNew"] as? Bool == expected.enabled)
                        #expect(row["admissionStatus"] as? String == (expected.enabled ? "available_for_new" : "grandfathered_current"))
                        if expected.enabled { #expect(row["admissionReason"] is NSNull) }
                        else { #expect(row["admissionReason"] as? String == "feature_flag_off") }
                    }
                }
            }
        }
    }
}

@Test func runtimeEnvMirrorsStayOutOfCanonicalConfigAndColdReads() async throws {
    let f = GrokPolicyFixture(.defaultOn)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let h = f.headers(user: f.owner, server: f.primary)
            func assertEnv(_ response: ClientResponse, user: [String: String], custom: Bool) throws {
                let value = try grokPolicyObject(response)
                let config = try #require(value["runtimeConfig"] as? [String: Any])
                let configEnv = try #require(config["envVars"] as? [String: String])
                #expect(configEnv == user)
                #expect(configEnv["ANTHROPIC_BASE_URL"] == nil)
                #expect(configEnv["ANTHROPIC_API_KEY"] == nil)
                #expect(configEnv["ANTHROPIC_CUSTOM_MODEL_OPTION"] == nil)
                var derived = user
                derived["ANTHROPIC_CUSTOM_MODEL_OPTION"] = "canonical-model"
                if custom {
                    derived["ANTHROPIC_BASE_URL"] = "https://canonical.example.test/api"
                    derived["ANTHROPIC_API_KEY"] = "fixture-canonical-key"
                }
                #expect(value["envVars"] as? [String: String] == derived)
            }
            for custom in [false, true] {
                for top in [false, true] {
                    let injected: [String: String] = ["KEEP": "before", "ANTHROPIC_EXTRA": "ordinary", "ANTHROPIC_BASE_URL": "https://injected.example.test", "ANTHROPIC_API_KEY": "injected", "ANTHROPIC_CUSTOM_MODEL_OPTION": "injected-model"]
                    let provider: [String: Any] = custom
                        ? ["kind": "custom", "apiUrl": "https://canonical.example.test/api", "apiKey": "fixture-canonical-key"]
                        : ["kind": "default"]
                    var fields: [String: Any] = ["name": "Env boundary \(custom) \(top)", "runtimeConfig": ["version": 1, "runtime": "claude", "provider": provider, "model": ["kind": "custom", "name": "canonical-model"], "envVars": injected]]
                    if top { fields["envVars"] = injected }
                    let bytes = try JSONSerialization.data(withJSONObject: fields)
                    let created = try await client.send(.post, headers: h, to: "/api/agents") { $0.body = .init(string: String(decoding: bytes, as: UTF8.self)) }
                    #expect(created.status == .ok)
                    try assertEnv(created, user: ["KEEP": "before", "ANTHROPIC_EXTRA": "ordinary"], custom: custom)
                    let id = try #require(try grokPolicyObject(created)["id"] as? String)
                    let path = URI(string: "/api/agents/\(id)")
                    try assertEnv(try await client.get(path, headers: h), user: ["KEEP": "before", "ANTHROPIC_EXTRA": "ordinary"], custom: custom)
                    var changed = injected; changed["KEEP"] = "after"
                    let update = try JSONSerialization.data(withJSONObject: ["envVars": changed])
                    let patch = try await client.send(.patch, headers: h, to: path) { $0.body = .init(string: String(decoding: update, as: UTF8.self)) }
                    #expect(patch.status == .ok)
                    try assertEnv(patch, user: ["KEEP": "after", "ANTHROPIC_EXTRA": "ordinary"], custom: custom)
                    try assertEnv(try await client.get(path, headers: h), user: ["KEEP": "after", "ANTHROPIC_EXTRA": "ordinary"], custom: custom)
                    let clear = try await client.send(.patch, headers: h, to: path) { $0.body = .init(string: "{\"envVars\":null}") }
                    #expect(clear.status == .ok)
                    try assertEnv(clear, user: [:], custom: custom)
                    try assertEnv(try await client.get(path, headers: h), user: [:], custom: custom)
                }
            }
            // These keys are ordinary user env for Codex/Grok, not Claude mirrors.
            for runtime in ["codex", "grok"] {
                let fields: [String: Any] = ["name": "Unowned env \(runtime)", "runtimeConfig": ["version": 1, "runtime": runtime, "model": ["kind": "custom", "name": "protocol-only-model"], "envVars": ["ANTHROPIC_API_KEY": "ordinary-for-this-runtime"]]]
                let bytes = try JSONSerialization.data(withJSONObject: fields)
                let response = try await client.send(.post, headers: h, to: "/api/agents") { $0.body = .init(string: String(decoding: bytes, as: UTF8.self)) }
                #expect(response.status == .ok)
                let config = try #require(try grokPolicyObject(response)["runtimeConfig"] as? [String: Any])
                #expect(config["envVars"] as? [String: String] == ["ANTHROPIC_API_KEY": "ordinary-for-this-runtime"])
            }
        }
    }
}

@Test func runtimeRawPatchHintsAndHydratedLegacyValuesValidateBeforeWrites() async throws {
    let f = GrokPolicyFixture(.defaultOn)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let h = f.headers(user: f.owner, server: f.primary)
            let codex: [String: Any] = ["version": 1, "runtime": "codex", "model": ["kind": "custom", "name": "protocol-only-model"]]
            var sequence = 0
            func post(_ extra: [String: Any]) async throws -> ClientResponse {
                sequence += 1; var fields = extra; fields["name"] = "Legacy boundary \(sequence)"
                let data = try JSONSerialization.data(withJSONObject: fields)
                return try await client.send(.post, headers: h, to: "/api/agents") { $0.body = .init(string: String(decoding: data, as: UTF8.self)) }
            }
            let created = try await post(["runtimeConfig": codex])
            #expect(created.status == .ok)
            let id = try #require(try grokPolicyObject(created)["id"] as? String)
            let path = URI(string: "/api/agents/\(id)")
            let before = try await client.get(path, headers: h)
            func patch(_ fields: [String: Any]) async throws -> ClientResponse {
                let bytes = try JSONSerialization.data(withJSONObject: fields)
                return try await client.send(.patch, headers: h, to: path) { $0.body = .init(string: String(decoding: bytes, as: UTF8.self)) }
            }
            let badRuntimeValues: [Any] = [NSNull(), false, 17, ["grok"], ["runtime": "grok"]]
            for invalid in badRuntimeValues {
                let response = try await patch(["runtime": invalid, "runtimeConfig": codex, "reasoningEffort": false, "restartMode": "bad", "serverRole": "bad", "description": "must not write"])
                #expect(response.status == .badRequest)
                #expect(try grokPolicyObject(response)["error"] as? String == "Runtime must be a string")
                let cold = try await client.get(path, headers: h); #expect(cold.body.string == before.body.string)
            }
            for invalid in [" grok ", "unknown-runtime", ""] {
                let response = try await patch(["runtime": invalid, "runtimeConfig": codex, "restartMode": "bad", "serverRole": "bad"])
                #expect(response.status == .badRequest)
                #expect(try grokPolicyObject(response)["error"] as? String == "Invalid runtime: \(invalid)")
                let cold = try await client.get(path, headers: h); #expect(cold.body.string == before.body.string)
            }
            let badEfforts: [(Any, String)] = [(false, "false"), (17, "17"), ("bogus", "bogus"), (" high ", " high "), ("", "")]
            for (value, text) in badEfforts {
                let response = try await patch(["runtimeConfig": codex, "reasoningEffort": value, "restartMode": "bad", "serverRole": "bad"])
                #expect(response.status == .badRequest)
                #expect(try grokPolicyObject(response)["error"] as? String == "Invalid reasoning effort: \(text)")
                let cold = try await client.get(path, headers: h); #expect(cold.body.string == before.body.string)
            }
            // Node raw-effort validation keeps the Kimi-SDK exception; the supplied
            // canonical Codex config wins, so this does not request a Kimi upgrade.
            let kimiHint = try await patch(["runtime": "kimi-sdk", "runtimeConfig": codex, "reasoningEffort": false])
            #expect(kimiHint.status == .ok)
            #expect(try grokPolicyObject(kimiHint)["runtime"] as? String == "codex")
            let nullable = try await patch(["runtimeConfig": codex, "reasoningEffort": NSNull()])
            #expect(nullable.status == .ok)
            let listBefore = try await client.get("/api/agents", headers: h)
            for (value, text) in badEfforts {
                let response = try await post(["runtime": "codex", "reasoningEffort": value])
                #expect(response.status == .badRequest)
                #expect(try grokPolicyObject(response)["error"] as? String == "Invalid reasoning effort: \(text)")
            }
            for runtime in ["cursor", "opencode"] {
                let response = try await post(["runtime": runtime, "reasoningEffort": "high"])
                #expect(response.status == .badRequest)
                #expect(try grokPolicyObject(response)["error"] as? String == "runtimeConfig.reasoningEffort is not supported for runtime: \(runtime)")
            }
            for (url, key, error) in [
                ("not-url", "key", "runtimeConfig.provider.apiUrl must be a valid URL"),
                ("https://", "key", "runtimeConfig.provider.apiUrl must be a valid URL"),
                ("https://provider.example.test:99999", "key", "runtimeConfig.provider.apiUrl must be a valid URL"),
                ("https:user:pass@example.test", "key", "runtimeConfig.provider.apiUrl must not contain credentials"),
                (" https://user:pass@example.test ", "key", "runtimeConfig.provider.apiUrl must not contain credentials"),
                ("https://user:pass@example.test", "key", "runtimeConfig.provider.apiUrl must not contain credentials"),
                (" ", "key", "runtimeConfig.provider.apiUrl is required"),
                ("https://provider.example.test", " ", "runtimeConfig.provider.apiKey is required"),
            ] {
                let response = try await post(["runtime": "claude", "envVars": ["ANTHROPIC_BASE_URL": url, "ANTHROPIC_API_KEY": key]])
                #expect(response.status == .badRequest)
                #expect(try grokPolicyObject(response)["error"] as? String == error)
            }
            let listAfter = try await client.get("/api/agents", headers: h)
            #expect(listAfter.body.string == listBefore.body.string)
            for runtime in ["codex", "cursor"] {
                let response = try await post(["runtime": runtime, "reasoningEffort": NSNull()])
                #expect(response.status == .ok)
            }
            let trimmedPost = try await post(["runtime": " codex ", "reasoningEffort": NSNull()])
            #expect(trimmedPost.status == .ok)
            var trimmed = codex; trimmed["runtime"] = " codex "
            let trimmedPatch = try await patch(["runtimeConfig": trimmed])
            #expect(trimmedPatch.status == .ok)
            #expect(try grokPolicyObject(trimmedPatch)["runtime"] as? String == "codex")
        }
    }
}
