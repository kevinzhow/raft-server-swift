import Configuration
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RaftConnectAuth
import RaftHTTPServer
import RaftMachineSocket
import RaftPersistence
import RaftRealtime
import RaftShared
import TestSupport
import Synchronization
import Vapor
@testable import RaftHTTP
@testable import RaftServer

struct ProtocolPGHTTPResponse: Sendable, CustomStringConvertible {
    let status: Int
    let body: Data
    var description: String { "ProtocolPGHTTPResponse(status: \(status), body: redacted)" }
    func object() throws -> ProtocolPGObject { try .init(data: body) }
}

/// Pure decoded evidence from a second real PostgreSQL client. It allocates no
/// Store or execution graph after activate has sealed TransactionDomain.shared.
struct ProtocolPGAudit: Sendable, CustomStringConvertible {
    let execution: AgentExecutionState
    let canonicalAgents: ProtocolPGObject
    let messages: [ProtocolPGObject]
    /// Formal mention rows, including the optional occurrence group. The
    /// acceptance asserts the durable occurrence without opening the database.
    let mentions: [ProtocolPGObject]
    let tasks: [ProtocolPGObject]
    var description: String { "ProtocolPGAudit(redacted)" }
    func status(agent: String) -> String? { canonicalAgents.object(agent)?.string("status") }
}

private struct ProtocolPGExecutionPayload: Codable, Sendable { let execution: AgentExecutionState? }

func protocolPGEventually(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while ContinuousClock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw ProtocolPGFailure.timeout
}

private func protocolPGDeadline<Value: Sendable>(onTimeout: @escaping @Sendable () -> Void,
    _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        defer { group.cancelAll() }
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(15))
            onTimeout()
            throw ProtocolPGFailure.timeout
        }
        guard let first = try await group.next() else { throw ProtocolPGFailure.closed }
        group.cancelAll()
        return first
    }
}

/// Local test stack only. Synthetic verified accounts are fixture business facts;
/// they are never reported as real email delivery or mailbox verification.
final class AgentExecutionPostgresFixture: Sendable {
    let accounts: EmailLoginDirectory
    let runtime: BusinessPersistenceRuntime
    let observer: PostgresPersistence
    let executionConnection: ProductionAgentExecutionConnection
    let machineServer: MachineConnectServer
    let realtimeServer: RealtimeServer
    let publications: ProductionRealtimePublicationWorker
    let app: Application
    let httpTask: Task<Void, any Error>
    let baseURL: URL
    let session: URLSession
    let serverId: String
    let slug: String
    let ownerEmail: String
    let memberEmail: String
    let outsiderEmail: String
    private let keys: [DurableKey]
    private let resumedPublications = Mutex<ProductionRealtimePublicationWorker?>(nil)

    private init(accounts: EmailLoginDirectory, runtime: BusinessPersistenceRuntime, observer: PostgresPersistence,
                 executionConnection: ProductionAgentExecutionConnection, machineServer: MachineConnectServer,
                 realtimeServer: RealtimeServer, publications: ProductionRealtimePublicationWorker,
                 app: Application, httpTask: Task<Void, any Error>, baseURL: URL, keys: [DurableKey],
                 serverId: String, slug: String, ownerEmail: String, memberEmail: String, outsiderEmail: String) {
        self.accounts = accounts; self.runtime = runtime; self.observer = observer
        self.executionConnection = executionConnection; self.machineServer = machineServer
        self.realtimeServer = realtimeServer; self.publications = publications
        self.app = app; self.httpTask = httpTask; self.baseURL = baseURL; self.keys = keys
        self.serverId = serverId; self.slug = slug
        self.ownerEmail = ownerEmail; self.memberEmail = memberEmail; self.outsiderEmail = outsiderEmail
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: configuration)
    }

    static func start(databaseURL: String) async throws -> AgentExecutionPostgresFixture {
        let configuration = try PostgresPersistenceConfiguration(databaseURL: databaseURL)
        let accounts = EmailLoginDirectory()
        let nonce = UUID().uuidString.lowercased()
        let serverId = UUID().uuidString.lowercased()
        let ownerId = UUID().uuidString.lowercased()
        let memberId = UUID().uuidString.lowercased()
        let outsiderId = UUID().uuidString.lowercased()
        let slug = "protocol-pg-\(nonce.prefix(10))"
        let ownerEmail = "protocol-owner-\(nonce)@slock.test"
        let memberEmail = "protocol-member-\(nonce)@slock.test"
        let outsiderEmail = "protocol-outsider-\(nonce)@slock.test"
        for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail), (outsiderId, outsiderEmail)] {
            accounts.addAccount(id: id, email: email, password: "protocol-only-password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "Protocol PG", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
        accounts.oauthFlows.configureSigningSecret("isolated-protocol-pg-signing-\(nonce)")
        let bindings = try accounts.makeDurableBindings()
        let keys = bindings.map(\.key)
        // The runner supplies and later destroys this dedicated database. The
        // case never truncates, resets, drops, or falls back to DATABASE_URL.
        let observer = try await PostgresPersistence.start(configuration: configuration)
        var runtime: BusinessPersistenceRuntime?
        var connection: ProductionAgentExecutionConnection?
        var machine: MachineConnectServer?
        var realtime: RealtimeServer?
        var publication: ProductionRealtimePublicationWorker?
        var application: Application?
        var serving: Task<Void, any Error>?
        do {
            guard try await observer.readSnapshot(keys).isEmpty else { throw ProtocolPGFailure.databaseNotEmpty }
            let writer = try await BusinessPersistenceRuntime.start(configuration: configuration, bindings: bindings)
            runtime = writer
            let hub = RealtimeHub()
            accounts.realtimeRelay.install { room, event, payload in hub.emit(room: room, event: event, payloadJSON: payload) }
            let app = try Application(.testing, configuration: .init(address: .hostname("127.0.0.1", port: 0)),
                                      configReader: .init(providers: [EnvironmentVariablesProvider()]))
            application = app
            let probe: @Sendable () async throws -> Void = { _ = try await observer.readSnapshot(keys) }
            // The peer never dereferences this HTTPS configuration metadata.
            // HTTP admission uses the actual loopback listener; TLS and the
            // official Computer/Redis/egress deployment gate remain separate.
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: probe),
                pingDatabase: probe, releaseEnvironment: [:], emailAccounts: accounts, persistence: writer, realtime: hub,
                serverBaseURL: "https://protocol-pg.invalid"))
            try await app.boot()
            // All retained owners and registrar dependencies exist before sealing.
            try await writer.activate()
            let execution = try ProductionDaemonIntegration.connect(execution: accounts.agentExecution(persistence: writer),
                runtime: writer, materializer: accounts.agentExecutionMaterialization(persistence: writer,
                    serverURL: "https://protocol-pg.invalid"),
                onboardingBriefing: accounts.onboardingBriefing)
            connection = execution
            try await writer.execute {
                accounts.configureMachineQueries(ProductionMachineQueries(registry: execution.registry))
            }
            // This callback reflects an actual authenticated transport transition;
            // it never sets ready or invents inventory. Ready arrives on the wire.
            let listener = try await MachineConnectServer.start(lookup: ProductionMachineLookup(
                base: LedgerMachineLookup(runtimeForms: accounts.runtimeFormsAndProbes, fleet: accounts.computersFleet), runtime: writer),
                onStatusCommitted: { matched, online in
                    try await writer.execute {
                        accounts.setMachineOnline(machineId: matched.id, online: online)
                        let version = accounts.bumpMachineStatusVersion(machineId: matched.id)
                        let payload = ProtocolPGObject(["machineId": .string(matched.id), "status": .string(online ? "online" : "offline"),
                                                        "statusVersion": .integer(Int64(version))])
                        let text = String(decoding: try payload.data, as: UTF8.self)
                        DeferredEffects.emit { hub.emit(room: "server:\(matched.serverId)", event: "machine:status", payloadJSON: text) }
                    }
                }, commandRegistry: execution.registry)
            machine = listener
            let socketServer = try await RealtimeServer.start(auth: ProductionRealtimeAuth(
                base: LedgerRealtimeAuth(authCore: accounts.authCore, membership: accounts.socketMembership), runtime: writer), hub: hub)
            realtime = socketServer
            let publisher = try ProductionRealtimePublicationWorker(runtime: writer, hub: hub)
            publication = publisher
            let task = Task { try await app.run() }
            serving = task
            let address = try await protocolPGDeadline(onTimeout: { task.cancel() }) { try await app.server.listeningAddress }
            guard let port = address.port, let baseURL = URL(string: "http://127.0.0.1:\(port)") else { throw ProtocolPGFailure.invalidResponse }
            return .init(accounts: accounts, runtime: writer, observer: observer, executionConnection: execution,
                machineServer: listener, realtimeServer: socketServer, publications: publisher,
                app: app, httpTask: task, baseURL: baseURL, keys: keys, serverId: serverId, slug: slug,
                ownerEmail: ownerEmail, memberEmail: memberEmail, outsiderEmail: outsiderEmail)
        } catch {
            await publication?.stop()
            await connection?.worker.stop()
            serving?.cancel()
            if let serving { _ = await serving.result }
            try? await machine?.close()
            await connection?.registry.close()
            try? await realtime?.close()
            try? await application?.shutdown()
            await runtime?.close()
            await observer.close()
            throw error
        }
    }

    func http(_ method: String, _ path: String, token: String? = nil, body: ProtocolPGObject? = nil) async throws -> ProtocolPGHTTPResponse {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: path, relativeTo: baseURL),
              url.host == "127.0.0.1", url.port == baseURL.port else { throw ProtocolPGFailure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(serverId, forHTTPHeaderField: "X-Server-Id")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try body.data }
        let (bytes, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.host == "127.0.0.1",
              bytes.count <= 2 * 1024 * 1024 else { throw ProtocolPGFailure.invalidResponse }
        return .init(status: response.statusCode, body: bytes)
    }
    func login(_ email: String) async throws -> String {
        let response = try await http("POST", "/api/auth/login", body: .init([
            "email": .string(email), "password": .string("protocol-only-password123")]))
        guard response.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        return try response.object().requireString("accessToken")
    }
    func subscriber(token: String) async throws -> ProtocolPGSocket {
        let socket = try await ProtocolPGSocket.connect(port: realtimeServer.port, path: "/socket.io/?EIO=4&transport=websocket")
        do {
            _ = try await socket.nextText { $0.hasPrefix("0{") }
            let auth = ProtocolPGObject(["token": .string(token), "serverId": .string(serverId), "clientKind": .string("web")])
            try await socket.send("40" + String(decoding: auth.data, as: UTF8.self))
            _ = try await socket.nextText { $0.hasPrefix("40{") }
            _ = try await socket.nextText { $0 == "42[\"rooms:joined\"]" }
            return socket
        } catch { await socket.close(); throw error }
    }

    /// One repeatable-read snapshot spanning the fourteen actual PG documents.
    /// The writer now commits only the rows a request actually changed (the
    /// fail-closed incident fix), so revisions legitimately differ per document;
    /// the repeatable-read transaction is what makes the snapshot coherent.
    func audit() async throws -> ProtocolPGAudit {
        let documents = try await observer.readSnapshot(keys)
        guard documents.count == keys.count else {
            throw ProtocolPGFailure.invalidSnapshot
        }
        func bytes(_ domain: DurableDomain) throws -> Data {
            guard let document = documents.first(where: { $0.key.domain == domain && $0.key.aggregateID == "root" }),
                  document.codecVersion == 1 else { throw ProtocolPGFailure.invalidSnapshot }
            return try document.decode(Data.self, codecVersion: 1)
        }
        do {
            let executionPayload = try RuntimePersistenceFormat.decode(ProtocolPGExecutionPayload.self,
                from: bytes(.agentsRuntime), domain: "raft.agents-runtime")
            guard let execution = executionPayload.execution else { throw ProtocolPGFailure.invalidSnapshot }
            try execution.validate()
            let oauth = try ProtocolPGObject(data: bytes(.oauthLedger))
            let messaging = try ProtocolPGObject(data: bytes(.messagesAndThreads))
            let collaboration = try ProtocolPGObject(data: bytes(.tasksAndReminders))
            guard oauth.string("format") == "raft.oauth-ledger", oauth.integer("version") == 1,
                  let canonical = oauth.object("businessState")?.object("agents"),
                  messaging.string("owner") == "messages-and-threads", messaging.integer("version") == 1,
                  let messages = messaging.object("payload")?.array("humanMessageRows"),
                  let mentions = messaging.object("payload")?.array("storedMentions"),
                  collaboration.string("format") == "raft.tasks-and-reminders", collaboration.integer("version") == 1,
                  let tasks = collaboration.object("business")?.array("taskRecords") else { throw ProtocolPGFailure.invalidSnapshot }
            func rows(_ values: [JSONValue]) throws -> [ProtocolPGObject] {
                try values.map { value in guard case .object(let row) = value else { throw ProtocolPGFailure.invalidSnapshot }; return .init(row) }
            }
            return try .init(execution: execution, canonicalAgents: canonical, messages: rows(messages),
                             mentions: rows(mentions), tasks: rows(tasks))
        } catch { throw ProtocolPGFailure.invalidSnapshot }
    }
    func outbox(_ commandId: UUID) async throws -> DurableOutboxEntry? { try await observer.outboxEffect(effectID: commandId) }
    /// Pause the real consumer to expose an independently committed pending row;
    /// restarting creates the same production worker, never an injected sink.
    func pausePublications() async { await publications.stop() }
    func resumePublications() throws {
        guard resumedPublications.withLock({ $0 == nil }) else { throw ProtocolPGFailure.invalidResponse }
        let publisher = try ProductionRealtimePublicationWorker(runtime: runtime, hub: realtimeServer.hub)
        resumedPublications.withLock { $0 = publisher }
    }
    func pendingTaskPublication(taskId: String, channelId: String) async throws -> DurableOutboxEntry? {
        let entries = try await observer.pendingOutbox(limit: 32)
        return entries.first { entry in
            guard entry.effect.kind.rawValue == "realtime.publish",
                  let envelope = try? JSONDecoder().decode(RealtimePublication.self, from: entry.effect.payload),
                  envelope.codec == "raft-realtime-publication-v1", envelope.room == "channel:\(channelId)",
                  envelope.event == "task:created" else { return false }
            return envelope.payloadJSON.contains(taskId)
        }
    }
    func close(machine: ControlledMachineProtocolPeer? = nil, subscriber: ProtocolPGSocket? = nil) async {
        // Stop workers before any listener/registry. Keep the writer alive until
        // all real peer-close/offline callbacks have finished their transactions.
        await publications.stop()
        let resumed = resumedPublications.withLock { $0 }
        await resumed?.stop()
        await executionConnection.worker.stop()
        httpTask.cancel(); _ = await httpTask.result
        session.invalidateAndCancel()
        await subscriber?.close()
        await machine?.socket.close()
        try? await machineServer.close()
        await executionConnection.registry.close()
        try? await realtimeServer.close()
        try? await app.shutdown()
        await runtime.close()
        await observer.close()
    }
}
