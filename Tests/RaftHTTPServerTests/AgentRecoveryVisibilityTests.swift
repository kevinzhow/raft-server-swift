import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftShared
import Testing
import TestSupport
import Vapor
import VaporTesting


@Suite(.serialized) struct AgentRecoveryVisibilityTests {
    /// Upstream RFC 071 §9 exposes a terminal-failure/manual-recovery block through
    /// the agent's typed activity (`activity` + `activityDetail` +
    /// `activityDetailKind` = `terminal_failure_paused`), never a private field.
    /// These published reads assert that carrier so the Web can show the warning.
    @Test func agentReadsExposeTheTerminalBreakerAsTypedOfflineActivity() async throws {
        let accounts = EmailLoginDirectory()
        let serverId = "33333333-3333-4333-8333-000000027001"
        let ownerId = "11111111-1111-4111-8111-000000027001"
        accounts.addAccount(id: ownerId, email: "breaker-visible@slock.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "breaker-visible", name: "Breaker Visible", ownerId: ownerId)
        let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "breaker-computer")
        accounts.machinesAndComputersStore.setMachineOnline(machineId: machine, online: true)
        let agentId = accounts.oauth.createAgent(serverId: serverId, name: "Cindy", runtime: "codex")
        accounts.oauth.setAgentStatus(id: agentId, status: "active")
        accounts.setAgentMachineForTesting(agentId: agentId, machineId: machine)
        accounts.agentsRuntimeStore.withState { state in
            state.execution.connections[machine] = AgentExecutionConnection(
                serverId: serverId, connectionEpochId: "visibility-epoch", online: true, ready: true,
                daemonInstanceId: "visibility-daemon", runtimes: ["codex"], capabilities: nil)
            var executionAgent = AgentExecutionAgent(serverId: serverId, machineId: machine)
            executionAgent.needsManual = "outcome_evidence_lost"
            state.execution.agents[agentId] = executionAgent
            // The daemon itself last reported a live idle process.
            state.agentActivities[agentId] = (activity: "online", detail: "")
            state.agentActivityDetailKind[agentId] = "idle"
            state.agentActivityObservedAt[agentId] = Date()
        }

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
            try await app.testing { client in
                var loginHeaders = HTTPFields()
                loginHeaders[.contentType] = "application/json"
                let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"breaker-visible@slock.test\",\"password\":\"password123\"}")
                }
                let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                func listedAgent() async throws -> [String: Any] {
                    let response = try await client.send(.get, headers: headers, to: "/api/agents")
                    #expect(response.status == .ok)
                    let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]]
                    return body?.first { $0["id"] as? String == agentId } ?? [:]
                }
                func detailedAgent() async throws -> [String: Any] {
                    let response = try await client.send(.get, headers: headers, to: "/api/agents/\(agentId)")
                    #expect(response.status == .ok)
                    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                }

                for row in [try await listedAgent(), try await detailedAgent()] {
                    #expect(row["status"] as? String == "active")
                    #expect(row["activity"] as? String == "offline",
                            "a manual-recovery block is the upstream offline activity, not the daemon's idle online fact")
                    #expect(row["activityDetail"] as? String
                            == "Automatic wake stopped: Runtime outcome reports for this agent were lost. A manual start is needed.")
                    #expect(row["activityDetailKind"] as? String == "terminal_failure_paused")
                }

                // Clearing the breaker restores the retained daemon activity; the
                // typed block never outlives the real recovery fact.
                accounts.agentsRuntimeStore.withState { $0.execution.agents[agentId]?.needsManual = nil }
                let recovered = try await listedAgent()
                #expect(recovered["activity"] as? String == "online")
                #expect(recovered["activityDetail"] as? String == "")
                #expect(recovered["activityDetailKind"] as? String == "idle")
            }
        }
    }

    /// The deployed production shape, driven through the same retained owners the
    /// ingress uses: an abandoned start left current by the old bug, a live
    /// resident process with completed launches, the connection-derived manual flag
    /// and a queued human DM. A complete ready retires the abandoned start, adopts
    /// the resident launch, clears the flag and releases the DM without a start.
    @Test func completeReadyRetiresTheAbandonedStartAndTheAgentReadsOnline() async throws {
        let accounts = EmailLoginDirectory()
        let serverId = "33333333-3333-4333-8333-000000027002"
        let ownerId = "11111111-1111-4111-8111-000000027002"
        let channelId = "22222222-2222-4222-8222-000000027002"
        accounts.addAccount(id: ownerId, email: "stale-recovery@slock.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "stale-recovery", name: "Stale Recovery", ownerId: ownerId)
        let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "resident-computer")
        accounts.machinesAndComputersStore.setMachineOnline(machineId: machine, online: true)
        let agentId = accounts.oauth.createAgent(serverId: serverId, name: "Cindy", runtime: "codex")
        accounts.oauth.setAgentStatus(id: agentId, status: "active")
        accounts.setAgentMachineForTesting(agentId: agentId, machineId: machine)
        accounts.addDirectMessage(serverId: serverId, channelId: channelId, participantIds: [ownerId, agentId], agentId: agentId)
        accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
        let messageId = accounts.oauth.createMessageRecord(
            channelId: channelId, content: "Are you there?", senderId: ownerId, seq: 43).id
        accounts.messagesAndThreadsStore.withState {
            $0.humanMessageRows.append(StoredHumanMessage(id: messageId, channelId: channelId, senderId: ownerId,
                                                          content: "Are you there?", seq: 43))
        }

        let domain = AgentExecutionDomain(
            agents: accounts.agentsRuntimeStore, machines: accounts.machinesAndComputersStore,
            oauth: accounts.oauth, channels: accounts.serversAndChannelsStore, messages: accounts.messagesAndThreadsStore)
        func commit<Value: Sendable>(_ operation: @Sendable () throws -> Value) async throws -> Value {
            let transaction = TransactionContext()
            return try await withTransactionContext(transaction) {
                let value = try operation()
                try transaction.prepareCommit()
                transaction.publishCommitted()
                transaction.flushDeferredEffects()
                return value
            }
        }
        let capabilities = ["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"]
        let first = AgentExecutionMachineContext(machineId: machine, serverId: serverId, connectionEpochId: "stale-connection-1")
        var completed: [AgentExecutionAdmission] = []
        try await commit {
            try domain.connectionOpened(first)
            try domain.observeReady(first, daemonInstanceId: "stale-daemon", capabilities: capabilities,
                                    runtimes: ["codex"], runningAgentIds: [], detectionComplete: true, unreliableAgentIds: [])
        }
        for index in 0..<3 {
            let admission = try await commit { try domain.requestStart(.init(serverId: serverId, agentId: agentId)) }
            let ack = try JSONSerialization.data(withJSONObject: [
                "type": "agent:start:ack", "agentId": agentId, "launchId": admission.launchId,
                "startDispatchId": try #require(admission.startDispatchId), "queueState": "running",
                "queueDepth": 0, "queueAgeMs": 0, "processInstanceId": "resident-process",
            ])
            _ = try await commit { try domain.stageIngress(context: first, type: "agent:start:ack", payload: ack) }
            let outcome = try JSONSerialization.data(withJSONObject: [
                "type": "agent:runtime:outcome", "v": 1, "agentId": agentId, "daemonInstanceId": "stale-daemon",
                "clientSeq": index + 1, "launchId": admission.launchId, "sessionId": "codex-session",
                "outcome": ["kind": "turn_completed"],
            ])
            _ = try await commit { try domain.stageIngress(context: first, type: "agent:runtime:outcome", payload: outcome) }
            completed.append(admission)
        }
        let resident = try #require(completed.last)
        let abandoned = try await commit { try domain.requestStart(.init(serverId: serverId, agentId: agentId)) }
        let startsBefore = accounts.agentsRuntimeStore.state.execution.commands.values.filter {
            $0.kind == .start && $0.agentId == agentId
        }.count
        try await commit { try domain.connectionClosed(first) }
        #expect(accounts.agentsRuntimeStore.state.execution.agents[agentId]?.needsManual
                == "connection_lost_with_unsettled_execution")
        let queued = try await commit {
            try domain.requestHumanMessageDelivery(.init(serverId: serverId, agentId: agentId,
                                                         channelId: channelId, messageId: messageId))
        }
        if case .readableOnly = queued {} else {
            Issue.record("the stale flag must keep the DM readable-only, got \(queued)")
        }

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
            try await app.testing { client in
                var loginHeaders = HTTPFields()
                loginHeaders[.contentType] = "application/json"
                let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"stale-recovery@slock.test\",\"password\":\"password123\"}")
                }
                let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                func listedAgent() async throws -> [String: Any] {
                    let response = try await client.send(.get, headers: headers, to: "/api/agents")
                    #expect(response.status == .ok)
                    let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]]
                    return body?.first { $0["id"] as? String == agentId } ?? [:]
                }

                // Before the next ready the stale flag is visible, never a silent
                // Online row with no warning.
                let stale = try await listedAgent()
                #expect(stale["activity"] as? String == "offline")
                #expect(stale["activityDetailKind"] as? String == "terminal_failure_paused")

                let second = AgentExecutionMachineContext(machineId: machine, serverId: serverId, connectionEpochId: "stale-connection-2")
                try await commit {
                    try domain.connectionOpened(second)
                    try domain.observeReady(second, daemonInstanceId: "stale-daemon", capabilities: capabilities,
                                            runtimes: ["codex"], runningAgentIds: [agentId], detectionComplete: true,
                                            unreliableAgentIds: [])
                }
                try await commit { try domain.releasePendingHumanDeliveries(second) }

                let agent = try #require(accounts.agentsRuntimeStore.state.execution.agents[agentId])
                #expect(agent.needsManual == nil)
                #expect(agent.currentLaunchId == resident.launchId)
                #expect(agent.launches[abandoned.launchId]?.notSpawned == true)
                let deliveries = accounts.agentsRuntimeStore.state.execution.commands.values.filter {
                    $0.kind == .delivery && $0.agentId == agentId && $0.messageId == messageId
                }
                #expect(deliveries.count == 1)
                #expect(deliveries.first?.launchId == resident.launchId)
                #expect(accounts.agentsRuntimeStore.state.execution.commands.values.filter {
                    $0.kind == .start && $0.agentId == agentId
                }.count == startsBefore, "no new start for a live resident process")

                let recovered = try await listedAgent()
                #expect(recovered["activity"] as? String == "online")
                #expect(recovered["activityDetail"] as? String == "")
                #expect(recovered["activityDetailKind"] as? String != "terminal_failure_paused")
            }
        }
    }

}
