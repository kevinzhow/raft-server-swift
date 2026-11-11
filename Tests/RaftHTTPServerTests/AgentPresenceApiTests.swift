import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftShared
import Synchronization
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Published `GET /api/agents` presence projection. The same retained stores
/// receive real daemon frames through the ingress domain; the HTTP layer must
/// publish their status/activity without inventing values.
@Test func agentListPublishesDaemonPresenceFacts() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000026001"
    let ownerId = "11111111-1111-4111-8111-000000026001"
    accounts.addAccount(id: ownerId, email: "presence-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "presence-api", name: "Presence API", ownerId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "presence-computer")
    accounts.machinesAndComputersStore.setMachineOnline(machineId: machine, online: true)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "Cindy", runtime: "codex")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)

    let domain = AgentExecutionDomain(
        agents: accounts.agentsRuntimeStore,
        machines: accounts.machinesAndComputersStore,
        oauth: accounts.oauth,
        channels: accounts.serversAndChannelsStore,
        messages: accounts.messagesAndThreadsStore
    )
    let machineContext = AgentExecutionMachineContext(machineId: machine, serverId: serverId,
                                                      connectionEpochId: "presence-connection")
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

    @Sendable func frame(_ type: String, body: [String: Any]) throws -> Data {
        var value: [String: Any] = ["type": type, "agentId": agent, "daemonInstanceId": "daemon-api", "clientSeq": 1]
        value.merge(body) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    }

    try await commit {
        try domain.connectionOpened(machineContext)
        try domain.connectionReady(machineContext, daemonInstanceId: "daemon-api",
                                   runtimes: ["codex"], runningAgentIds: [], detectionComplete: true)
    }

    let events = Mutex<[(room: String, event: String, payload: String?)]>([])
    accounts.realtimeRelay.install { room, event, payload in
        events.withLock { $0.append((room, event, payload)) }
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"presence-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func listedAgent() async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers, to: "/api/agents")
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]]
                return body?.first { $0["id"] as? String == agent } ?? [:]
            }

            // Baseline: a complete ready reports no running process for the
            // inactive agent; the reconcile keeps it inactive/offline with the
            // upstream runtime-interrupted detail.
            let baseline = try await listedAgent()
            #expect(baseline["status"] as? String == "inactive")
            #expect(baseline["activity"] as? String == "offline")
            #expect(baseline["activityDetail"] as? String == "Runtime interrupted")

            // The Computer reconnects with its idle Codex process alive:
            // ready.runningAgents makes the agent active and online
            // (upstream planReadyReconcileAction mark-active-online), which is
            // the production restart symptom this projection repairs. The
            // reported run is attributable to a process this server tracks;
            // an unknown process is the manual gate exercised separately.
            accounts.agentsRuntimeStore.withState { state in
                var executionAgent = AgentExecutionAgent(serverId: serverId, machineId: machine)
                executionAgent.processes["process-1"] = AgentExecutionProcess(
                    processInstanceId: "process-1", daemonInstanceId: "daemon-api",
                    spawnLaunchId: nil, launchIds: [])
                state.execution.agents[agent] = executionAgent
            }
            try await commit {
                try domain.connectionOpened(machineContext)
                try domain.connectionReady(machineContext, daemonInstanceId: "daemon-api",
                                           runtimes: ["codex"], runningAgentIds: [agent], detectionComplete: true)
            }
            let active = try await listedAgent()
            #expect(active["status"] as? String == "active")
            #expect(active["activity"] as? String == "online")
            #expect(active["activityDetail"] as? String == "")

            // The daemon's sequenced status frame keeps the same state.
            try await commit {
                try domain.stageIngress(context: machineContext, type: "agent:status",
                                        payload: try frame("agent:status", body: ["status": "active"]))
            }
            #expect((try await listedAgent())["status"] as? String == "active")

            // The daemon's live activity is projected with its detail.
            try await commit {
                try domain.stageIngress(context: machineContext, type: "agent:activity",
                                        payload: try frame("agent:activity", body: ["detail": "Planning the reply",
                                                                                   "detailKind": "thinking_started"]))
            }
            let thinking = try await listedAgent()
            #expect(thinking["activity"] as? String == "thinking")
            #expect(thinking["activityDetail"] as? String == "Planning the reply")
            let pushed = events.withLock { $0 }
            #expect(pushed.contains { $0.room == "server:\(serverId)" && $0.event == "agent:activity" })

            try await commit {
                try domain.stageIngress(context: machineContext, type: "agent:activity",
                                        payload: try frame("agent:activity", body: ["detail": "", "detailKind": "idle"]))
            }
            let online = try await listedAgent()
            #expect(online["activity"] as? String == "online")

            // A manual stop reads offline/Stopped before any cache lookup.
            accounts.oauth.setAgentStatus(id: agent, status: "stopped")
            let stopped = try await listedAgent()
            #expect(stopped["status"] as? String == "stopped")
            #expect(stopped["activity"] as? String == "offline")
            #expect(stopped["activityDetail"] as? String == "Stopped")
        }
    }
}
