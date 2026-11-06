import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private final class ServerEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []
    func append(_ room: String, _ event: String, _ payload: String?) {
        lock.lock(); storage.append((room, event, payload)); lock.unlock()
    }
    var values: [(room: String, event: String, payload: String?)] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

private func serverApiLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func serverApiHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func serverApiObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func serverEmailInviteRespectsSeatsAndAcceptsTheInvitee() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001020001"
    let ownerId = "11111111-1111-4111-8111-000001020001"
    let inviteeId = "11111111-1111-4111-8111-000001020002"
    let ownerEmail = "invite-seat-owner@slock.test"
    let inviteeEmail = "invite-seat-invitee@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (inviteeId, inviteeEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "invite-seat", name: "Invite Seat", ownerId: ownerId)
    accounts.setServerSeats(serverId: serverId, seats: 2)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await serverApiLogin(client, email: ownerEmail)
            let invitee = try await serverApiLogin(client, email: inviteeEmail)
            let headers = serverApiHeaders(owner, serverId)
            let created = try await client.send(.post, headers: headers, to: URI(string: "/api/servers/\(serverId)/invites")) { request in
                request.body = .init(string: "{\"email\":\"\(inviteeEmail)\",\"role\":\"member\"}")
            }
            #expect(created.status == .ok)
            let invite = try #require(try serverApiObject(created)["invite"] as? [String: Any])
            let inviteId = try #require(invite["id"] as? String)
            let token = "invite-token-\(inviteId)"
            accounts.setServerInviteTokenForTesting(inviteId: inviteId, token: token)

            let info = try await client.get(URI(string: "/api/auth/invite-info?token=\(token)"))
            #expect(info.status == .ok)
            #expect(try serverApiObject(info)["humanSeatLimitReached"] as? Bool == false)

            let accepted = try await client.send(.post, headers: serverApiHeaders(invitee, serverId), to: "/api/auth/accept-invite") { request in
                request.body = .init(string: "{\"token\":\"\(token)\"}")
            }
            #expect(accepted.status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: inviteeId) == "member")

            let full = try await client.send(.post, headers: headers, to: URI(string: "/api/servers/\(serverId)/invites")) { request in
                request.body = .init(string: "{\"email\":\"third@slock.test\",\"role\":\"member\"}")
            }
            #expect(full.status == .badRequest)

            accounts.enableGuestRoleTransitions(serverId: serverId)
            let guest = try await client.send(.post, headers: headers, to: URI(string: "/api/servers/\(serverId)/invites")) { request in
                request.body = .init(string: "{\"email\":\"guest@slock.test\",\"role\":\"guest\"}")
            }
            #expect(guest.status == .ok)

            let link = try await client.send(.post, headers: headers, to: URI(string: "/api/servers/\(serverId)/join-links")) { request in
                request.body = .init(string: "{}")
            }
            #expect(link.status == .ok)
        }
    }
}

@Test func serverMachineListProjectsCreatorAndComputerState() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001020003"
    let ownerId = "11111111-1111-4111-8111-000001020003"
    let memberId = "11111111-1111-4111-8111-000001020004"
    let ownerEmail = "machine-projection-owner@slock.test"
    let memberEmail = "machine-projection-member@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "machine-projection", name: "Machine Projection", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "owner-computer-machine")
    accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: ["codex"])
    accounts.linkComputerForTesting(serverId: serverId, machineId: machine, online: true, attachedByUserId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "owner-computer-agent", runtime: "codex")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)

    let departedMachine = accounts.registerMachine(serverId: serverId, userId: memberId, name: "departed-creator-computer-machine")
    accounts.linkComputerForTesting(serverId: serverId, machineId: departedMachine, online: true, attachedByUserId: memberId)
    accounts.oauth.removeMember(serverId: serverId, userId: memberId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await serverApiLogin(client, email: ownerEmail)
            let rowsResponse = try await client.get(
                URI(string: "/api/servers/\(serverId)/machines"),
                headers: serverApiHeaders(owner, serverId)
            )
            #expect(rowsResponse.status == .ok)
            let rows = try serverApiObject(rowsResponse)["machines"] as? [[String: Any]] ?? []
            let row = try #require(rows.first { $0["id"] as? String == machine })
            #expect(row["isComputer"] as? Bool == true)
            #expect(row["computerAttachedByCurrentUser"] as? Bool == true)
            #expect(row["agentCount"] as? Int == 1)
            #expect(row["runtimes"] as? [String] == ["codex"])
            #expect(row["computerAttachedByUserId"] == nil)
            let creator = try #require(row["creator"] as? [String: Any])
            #expect(creator["type"] as? String == "human")
            #expect(creator["id"] as? String == ownerId)
            #expect((creator["gravatarHash"] as? String)?.count == 64)

            let departed = try #require(rows.first { $0["id"] as? String == departedMachine })
            #expect(departed["creator"] is NSNull)
        }
    }
}

@Test func serverGrokRuntimeGateAndModelOutcomes() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001020005"
    let ownerId = "11111111-1111-4111-8111-000001020005"
    let ownerEmail = "grok-gate-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "grok-gate", name: "Grok Gate", ownerId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "grok-machine")
    accounts.setMachineRuntimesForTesting(machineId: machine, runtimes: ["codex", "grok"])
    let probe = RuntimeProbeCounter()
    accounts.machineRuntimeModelProbe = { _, _, _ in probe.next() }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await serverApiLogin(client, email: ownerEmail)
            let headers = serverApiHeaders(owner, serverId)
            let base = "/api/servers/\(serverId)/machines/\(machine)"
            func options() async throws -> [[String: Any]] {
                let response = try await client.get(URI(string: "\(base)/runtime-options"), headers: headers)
                #expect(response.status == .ok)
                return try serverApiObject(response)["options"] as? [[String: Any]] ?? []
            }
            #expect(try await options().contains { $0["runtimeId"] as? String == "grok" } == false)
            accounts.enableGrokRuntimeForTesting(serverId: serverId)
            #expect(try await options().contains { $0["runtimeId"] as? String == "grok" } == true)

            probe.outcome = .models(models: [RuntimeModelProbeModel(id: "grok-4.5", label: "Grok 4.5")], default: "grok-4.5")
            let live = try await client.get(URI(string: "\(base)/runtime-models/grok"), headers: headers)
            #expect(live.status == .ok)
            let liveBody = try serverApiObject(live)
            #expect(liveBody["models"] as? [[String: String]] == [["id": "grok-4.5", "label": "Grok 4.5"]])
            #expect(liveBody["default"] as? String == "grok-4.5")
            #expect(probe.calls == 1)

            probe.outcome = .missingConfig
            #expect(try serverApiObject(try await client.get(URI(string: "\(base)/runtime-models/codex"), headers: headers)) as NSDictionary == ["kind": "missing_config", "recovery": "kimi_login"] as NSDictionary)
            probe.outcome = .noModels
            #expect(try serverApiObject(try await client.get(URI(string: "\(base)/runtime-models/codex"), headers: headers)) as NSDictionary == ["kind": "no_models"] as NSDictionary)
            probe.outcome = .unsupported
            #expect(try serverApiObject(try await client.get(URI(string: "\(base)/runtime-models/codex"), headers: headers)) as NSDictionary == ["kind": "unsupported"] as NSDictionary)
            probe.outcome = .error(code: "", retryable: true)
            #expect(try serverApiObject(try await client.get(URI(string: "\(base)/runtime-models/codex"), headers: headers)) as NSDictionary == ["kind": "error", "retryable": true] as NSDictionary)
            probe.outcome = .error(code: "detect_timeout", retryable: true)
            #expect(try serverApiObject(try await client.get(URI(string: "\(base)/runtime-models/codex"), headers: headers)) as NSDictionary == ["kind": "error", "retryable": true, "code": "detect_timeout"] as NSDictionary)
        }
    }
}

private final class RuntimeProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls = 0
    var outcome: RuntimeModelProbeOutcome = .missingConfig
    var calls: Int {
        lock.lock(); defer { lock.unlock() }; return storedCalls
    }
    func next() -> RuntimeModelProbeOutcome {
        lock.lock(); storedCalls += 1; let value = outcome; lock.unlock(); return value
    }
}

@Test func serverDeleteBroadcastsRemovalToMembers() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001020006"
    let ownerId = "11111111-1111-4111-8111-000001020006"
    let adminId = "11111111-1111-4111-8111-000001020007"
    let memberId = "11111111-1111-4111-8111-000001020008"
    let ownerEmail = "delete-broadcast-owner@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (adminId, "delete-broadcast-admin@slock.test"), (memberId, "delete-broadcast-member@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "delete-broadcast", name: "Delete Broadcast", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let events = ServerEventCollector()
    accounts.realtimeRelay.install { room, event, payload in events.append(room, event, payload) }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await serverApiLogin(client, email: ownerEmail)
            let response = try await client.send(.delete, headers: serverApiHeaders(owner, serverId), to: URI(string: "/api/servers/\(serverId)"))
            #expect(response.status == .ok)
            let deleted = events.values.filter { $0.event == "server:deleted" }
            #expect(deleted.count == 1)
            #expect(deleted.first?.room == "server:\(serverId)")
            let removals = Set(events.values.filter { $0.event == "server:membership-removed" }.map(\.room))
            #expect(removals == Set(["user:\(ownerId)", "user:\(adminId)", "user:\(memberId)"]))
        }
    }
}

@Test func serverUpgradeGateClosesTheProjectionAndBothRoutes() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001020009"
    let ownerId = "11111111-1111-4111-8111-000001020009"
    let ownerEmail = "upgrade-gate-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "upgrade-gate", name: "Upgrade Gate", ownerId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "gated-computer")
    accounts.linkComputerForTesting(serverId: serverId, machineId: machine, online: true, version: "1.0.23", attachedByUserId: ownerId)
    accounts.setLatestComputerReleaseForTesting(version: "1.0.31", releaseNotesJSON: "{\"version\":\"1.0.31\"}")
    accounts.setMachineBroadcastPolicyForTesting(
        machineId: machine,
        policyJSON: "{\"eligibility\":\"eligible\",\"targetVersion\":\"1.0.31\",\"policyRevision\":\"test\",\"reasonCode\":\"eligible\"}"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await serverApiLogin(client, email: ownerEmail)
            let headers = serverApiHeaders(owner, serverId)
            func policy() async throws -> [String: Any] {
                let response = try await client.get(URI(string: "/api/servers/\(serverId)/machines"), headers: headers)
                let rows = try serverApiObject(response)["machines"] as? [[String: Any]] ?? []
                return try #require(rows.first { $0["id"] as? String == machine }?["computerBroadcastPolicy"] as? [String: Any])
            }
            func upgrade() async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: URI(string: "/api/servers/\(serverId)/machines/\(machine)/computer/upgrade")) { request in
                    request.body = .init(string: "{\"targetVersion\":\"1.0.31\"}")
                }
            }
            func lifecycle() async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: URI(string: "/api/servers/\(serverId)/machines/\(machine)/computer-lifecycle-operations")) { request in
                    request.body = .init(string: "{\"action\":\"upgrade\",\"operationId\":\"11111111-1111-4111-8111-000001020010\",\"parentOperationId\":\"11111111-1111-4111-8111-000001020011\",\"channel\":\"main\"}")
                }
            }

            #expect(try await policy()["reasonCode"] as? String == "eligible")
            accounts.setRemoteUpgradeGateForTesting(serverId: serverId, enabled: false)
            let closed = try await policy()
            #expect(closed["eligibility"] as? String == "no_broadcast")
            #expect(closed["reasonCode"] as? String == "broadcast_disabled")
            #expect(closed["targetVersion"] is NSNull)
            let refused = try await upgrade()
            #expect(refused.status == .forbidden)
            #expect(try serverApiObject(refused)["code"] as? String == "remote_upgrade_disabled")
            let lifecycleRefused = try await lifecycle()
            #expect(lifecycleRefused.status == .conflict)
            #expect((try serverApiObject(lifecycleRefused)["policy"] as? [String: Any])?["reasonCode"] as? String == "broadcast_disabled")

            accounts.setRemoteUpgradeGateForTesting(serverId: serverId, enabled: true)
            #expect(try await policy()["reasonCode"] as? String == "eligible")
            #expect(try await upgrade().status == .ok)
        }
    }
}

@Test func serverUpgradeWithoutTargetResolvesTheLatestReleaseAndRequiresDelivery() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001020012"
    let ownerId = "11111111-1111-4111-8111-000001020012"
    let ownerEmail = "upgrade-send-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "upgrade-send", name: "Upgrade Send", ownerId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "send-computer")
    accounts.linkComputerForTesting(serverId: serverId, machineId: machine, online: true, version: "1.0.23", attachedByUserId: ownerId)
    accounts.setLatestComputerReleaseForTesting(version: "1.0.31", releaseNotesJSON: "{\"version\":\"1.0.31\"}")
    let sent = ServerEventCollector()
    accounts.computerUpgradeSender = { machineId, target, requestId in
        sent.append(machineId, target, requestId)
        return true
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await serverApiLogin(client, email: ownerEmail)
            let headers = serverApiHeaders(owner, serverId)
            let lifecycle = try await client.send(.post, headers: headers, to: URI(string: "/api/servers/\(serverId)/machines/\(machine)/computer-lifecycle-operations")) { request in
                request.body = .init(string: "{\"action\":\"upgrade\",\"operationId\":\"11111111-1111-4111-8111-000001020013\",\"parentOperationId\":\"11111111-1111-4111-8111-000001020014\",\"channel\":\"main\"}")
            }
            #expect(lifecycle.status.code == 201)
            #expect(try serverApiObject(lifecycle)["targetVersion"] as? String == "1.0.31")

            let upgrade = try await client.send(.post, headers: headers, to: URI(string: "/api/servers/\(serverId)/machines/\(machine)/computer/upgrade")) { request in
                request.body = .init(string: "{\"targetVersion\":\"1.0.31\"}")
            }
            #expect(upgrade.status == .ok)
            #expect(sent.values.count == 1)
            #expect(sent.values.first?.event == "1.0.31")

            accounts.computerUpgradeSender = { _, _, _ in false }
            let undelivered = try await client.send(.post, headers: headers, to: URI(string: "/api/servers/\(serverId)/machines/\(machine)/computer/upgrade")) { request in
                request.body = .init(string: "{\"targetVersion\":\"1.0.31\"}")
            }
            #expect(undelivered.status == .conflict)
            #expect(try serverApiObject(undelivered)["code"] as? String == "computer_offline")
        }
    }
}
