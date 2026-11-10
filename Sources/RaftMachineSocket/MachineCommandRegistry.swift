import Foundation
import NIOCore

/// Correlation uses the existing upstream fields, never a new public wire envelope.
public struct MachineCommand: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case start, deliver, stop, resetWorkspace }
    public let kind: Kind
    public let id: String
    public let agentId: String
    public let launchId: String?
    public let deliverySequence: Int?
    /// A private expected-connection fence, or the upstream start epoch. This
    /// metadata never adds a field to the original command JSON.
    public let connectionEpochId: String?
    public let runtime: String?
    public let json: String

    public init(json: String, expectedConnectionEpochId: String? = nil) throws {
        guard json.utf8.count <= 1_048_576 else { throw MachineCommandError.invalidCommand }
        let value = try JSONDecoder().decode(MachineCommandFields.self, from: Data(json.utf8))
        guard let agent = value.agentId, !agent.isEmpty else { throw MachineCommandError.invalidCommand }
        if let expectedConnectionEpochId {
            guard !expectedConnectionEpochId.isEmpty else { throw MachineCommandError.invalidCommand }
            if let wireEpoch = value.connectionEpochId, wireEpoch != expectedConnectionEpochId {
                throw MachineCommandError.disconnected
            }
        }
        switch value.type {
        case "agent:start":
            guard let id = value.startDispatchId, !id.isEmpty,
                  let launch = value.launchId, !launch.isEmpty else { throw MachineCommandError.invalidCommand }
            kind = .start; self.id = id; launchId = launch; deliverySequence = nil
        case "agent:deliver":
            guard let id = value.deliveryId, !id.isEmpty, let seq = value.seq else {
                throw MachineCommandError.invalidCommand
            }
            kind = .deliver; self.id = id; launchId = nil; deliverySequence = seq
        case "agent:stop":
            // Local bookkeeping only: the upstream stop wire has no request ID or ACK.
            kind = .stop; self.id = "stop:\(agent)"; launchId = nil; deliverySequence = nil
        case "agent:reset-workspace":
            // Private bookkeeping only; no request ID or completion contract is
            // added to the upstream wire body.
            kind = .resetWorkspace; self.id = "workspace-reset:\(agent)"; launchId = nil; deliverySequence = nil
        default: throw MachineCommandError.unsupportedCommand
        }
        agentId = agent
        connectionEpochId = expectedConnectionEpochId ?? value.connectionEpochId
        runtime = value.runtime
        self.json = json
    }
}

struct MachineCommandFields: Decodable, Sendable {
    let type: String
    var agentId: String?
    var startDispatchId: String?
    var launchId: String?
    var deliveryId: String?
    var seq: Int?
    var daemonInstanceId: String?
    var clientSeq: Int?
    var supersededLaunchIds: [String]?
    var connectionEpochId: String?
    var runtime: String?
    var queueState: String?
    var queueDepth: Int?
    var queueAgeMs: Int?
    var processInstanceId: String?
    var result: StartResult?
    struct StartResult: Decodable, Sendable { let kind: String; var processInstanceId: String?; var reason: String? }
}

public enum MachineCommandError: Error, Sendable, Equatable {
    case invalidCommand, unsupportedCommand, machineOffline, disconnected, timedOut
    case duplicatePendingCommand, noOutcomeContract, protocolViolation
    case rejected(String)
    case runtimeUnavailable
}

public struct MachineCommandReply: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case acknowledgement, outcome }
    public let commandId: String
    public let stage: Stage
    /// The original upstream JSON. An ACK means receipt/admission, not model execution.
    public let json: String
}

/// Live channels are authority-scoped to the authenticated machine and connection epoch.
/// Durable mode relays only the ACK descriptor returned by the authorized consumer
/// after its transaction. Legacy callbacks retain command-protocol compatibility.
public actor MachineCommandRegistry {
    public typealias Commit = @Sendable (_ machineId: String, _ json: String) async throws -> Void
    private struct Connection: Sendable {
        let epoch: String
        let serverId: String
        let channel: any Channel
        var ready = false
        var daemonReady: MachineDaemonReady?
        var workspaceScanDaemonInstanceId: String?
    }
    private struct Pending {
        let epoch: String
        let command: MachineCommand
        let stage: MachineCommandReply.Stage
        let continuation: CheckedContinuation<MachineCommandReply, any Error>
        let timeout: Task<Void, Never>
        let acknowledgementTimeout: Task<Void, Never>?
    }
    private var connections: [String: Connection] = [:]
    private struct Transport: Sendable { let channel: any Channel; let finished: EventLoopPromise<Void> }
    private var transports: [String: Transport] = [:]
    private var stopping = false
    private var statusCommitFailures: Set<String> = []
    private var pending: [String: [String: Pending]] = [:]
    private struct PendingQuery {
        let epoch: String
        let request: MachineQueryRequest
        let continuation: CheckedContinuation<MachineQueryReply, any Error>
        let timeout: Task<Void, Never>
    }
    private var pendingQueries: [String: [String: PendingQuery]] = [:]
    private struct WorkspaceScanFlight {
        let epoch: String
        let daemonInstanceId: String
        let pendingId: String
    }
    // Keep ambiguity across socket reconnects during this Main lifetime. The
    // legacy daemon's unfinished promise can send its result on a new socket.
    private var workspaceScanFlights: [String: WorkspaceScanFlight] = [:]
    private let commit: Commit?
    private let durableIngress: MachineDurableIngress?
    public nonisolated let durableOutcomeAcknowledgementsEnabled: Bool
    private var ingressContexts: [String: MachineIngressContext] = [:]

    /// Compatibility mode does not advertise or infer durable outcome ACKs.
    public init(onMessageCommitted: Commit? = nil) {
        commit = onMessageCommitted
        durableIngress = nil
        durableOutcomeAcknowledgementsEnabled = false
    }

    public init(durableIngress: MachineDurableIngress) {
        commit = nil
        self.durableIngress = durableIngress
        durableOutcomeAcknowledgementsEnabled = true
    }

    func openTransport(epoch: String, channel: any Channel) throws {
        guard !stopping else { throw MachineCommandError.disconnected }
        transports[epoch] = Transport(channel: channel, finished: channel.eventLoop.makePromise(of: Void.self))
    }

    func finishTransport(epoch: String) async {
        if let context = ingressContexts.removeValue(forKey: epoch), let durableIngress {
            do { try await durableIngress.onClosed(context) }
            catch { statusCommitFailures.insert(context.machineId) }
        }
        transports.removeValue(forKey: epoch)?.finished.succeed(())
    }

    func statusCommitFailed(machineId: String) { statusCommitFailures.insert(machineId) }
    public func machinesWithStatusCommitFailure() -> Set<String> { statusCommitFailures }

    func register(machineId: String, serverId: String, epoch: String, channel: any Channel) async throws {
        guard !stopping, channel.isActive else { throw MachineCommandError.disconnected }
        let old = connections.updateValue(Connection(epoch: epoch, serverId: serverId, channel: channel), forKey: machineId)
        if let old {
            fail(machineId: machineId, epoch: old.epoch, error: MachineCommandError.disconnected)
            let finished = transports[old.epoch]?.finished.futureResult
            old.channel.close(promise: nil)
            if let finished { try await finished.get() }
        }
        // A replacement's offline commit finishes before the next online commit.
        guard connections[machineId]?.epoch == epoch, channel.isActive, !stopping else { throw MachineCommandError.disconnected }
        if let durableIngress {
            let context = MachineIngressContext(machineId: machineId, serverId: serverId, connectionEpochId: epoch)
            ingressContexts[epoch] = context
            try await durableIngress.onOpened(context)
            guard connections[machineId]?.epoch == epoch, channel.isActive, !stopping else {
                throw MachineCommandError.disconnected
            }
        }
    }

    func ready(machineId: String, epoch: String) {
        guard let connection = connections[machineId], connection.epoch == epoch, connection.channel.isActive else { return }
        connections[machineId]?.ready = true
    }

    func disconnect(machineId: String, epoch: String) {
        guard connections[machineId]?.epoch == epoch else { return }
        connections.removeValue(forKey: machineId)
        fail(machineId: machineId, epoch: epoch, error: MachineCommandError.disconnected)
    }

    /// Socket online is separate from a committed executable inventory.
    public func isOnline(machineId: String) -> Bool { connections[machineId]?.ready == true }
    public func daemonReady(machineId: String) -> MachineDaemonReady? { connections[machineId]?.daemonReady }
    public func isExecutionReady(machineId: String, runtime: String) -> Bool {
        guard let connection = connections[machineId], connection.ready, connection.channel.isActive,
              let inventory = connection.daemonReady, inventory.hasCompleteInventory else { return false }
        return inventory.runtimes?.contains(runtime) == true && inventory.capabilities?.contains("agent:start") == true
    }
    public func connectionEpoch(machineId: String) -> String? {
        guard let connection = connections[machineId], connection.ready else { return nil }
        return connection.epoch
    }

    /// Read-only RPC uses the existing channel and never borrows execution
    /// readiness as inventory or opens another connection.
    public func query(_ request: MachineQueryRequest, machineId: String, serverId: String,
                      expectedConnectionEpochId epoch: String, timeout: Duration = .seconds(30)) async throws -> MachineQueryReply {
        try Task.checkCancellation()
        guard !stopping, let connection = connections[machineId], connection.serverId == serverId,
              connection.epoch == epoch, connection.ready, connection.channel.isActive else { throw MachineCommandError.machineOffline }
        guard pendingQueries[machineId, default: [:]].count < 128 else { throw MachineCommandError.duplicatePendingCommand }
        let id = UUID().uuidString
        let data = try request.encoded(requestId: id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if case .workspaceScan = request {
                    do { try admitWorkspaceScan(machineId: machineId, epoch: epoch, pendingId: id) }
                    catch { continuation.resume(throwing: error); return }
                }
                let timer = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self.failQuery(machineId: machineId, id: id, epoch: epoch, error: MachineCommandError.timedOut)
                }
                pendingQueries[machineId, default: [:]][id] = PendingQuery(epoch: epoch, request: request,
                    continuation: continuation, timeout: timer)
                Task {
                    do {
                        guard self.connections[machineId]?.epoch == epoch, connection.channel.isActive,
                              self.pendingQueries[machineId]?[id]?.epoch == epoch else { throw MachineCommandError.disconnected }
                        try await MachineCommandWebSocket.write(opcode: 1, payload: Array(data), channel: connection.channel).get()
                    } catch { self.failQuery(machineId: machineId, id: id, epoch: epoch, error: error) }
                }
            }
        } onCancel: {
            Task { await self.failQuery(machineId: machineId, id: id, epoch: epoch, error: CancellationError()) }
        }
    }

    private func admitWorkspaceScan(machineId: String, epoch: String, pendingId: String) throws {
        guard let connection = connections[machineId], connection.epoch == epoch,
              connection.ready, connection.channel.isActive else { throw MachineCommandError.disconnected }
        guard let daemon = connection.workspaceScanDaemonInstanceId, !daemon.isEmpty else {
            throw MachineCommandError.protocolViolation
        }
        if let prior = workspaceScanFlights[machineId] {
            // A different ID cannot supersede a STILL pending scan. Once the old
            // flight has failed, only an actual different daemon can recover it.
            guard pendingQueries[machineId]?[prior.pendingId] == nil,
                  prior.daemonInstanceId != daemon else { throw MachineCommandError.duplicatePendingCommand }
        }
        workspaceScanFlights[machineId] = .init(epoch: epoch, daemonInstanceId: daemon, pendingId: pendingId)
    }

    private func correlateQuery(machineId: String, epoch: String, payload: Data) {
        guard let header = try? JSONDecoder().decode(MachineQueryReplyHeader.self, from: payload) else { return }
        // Existing tree replies retain Node's identical-request matching. Scan
        // replies instead require their sole flight and current daemon identity.
        for (id, value) in pendingQueries[machineId] ?? [:]
            where value.epoch == epoch && value.request.matches(header, requestId: id) {
            if case .workspaceScan = value.request {
                guard let scan = workspaceScanFlights[machineId], scan.pendingId == id, scan.epoch == epoch,
                      connections[machineId]?.workspaceScanDaemonInstanceId == scan.daemonInstanceId else {
                    failQuery(machineId: machineId, id: id, epoch: epoch, error: MachineCommandError.protocolViolation)
                    continue
                }
                workspaceScanFlights.removeValue(forKey: machineId)
            }
            pendingQueries[machineId]?.removeValue(forKey: id)
            value.timeout.cancel()
            value.continuation.resume(returning: .init(payload: payload, connectionEpochId: epoch))
        }
    }

    private func failQuery(machineId: String, id: String, epoch: String, error: any Error) {
        guard let pending = pendingQueries[machineId]?[id], pending.epoch == epoch else { return }
        pendingQueries[machineId]?.removeValue(forKey: id)
        // Do not clear workspaceScanFlights here: timeout/cancel/write failure
        // (including disconnect) cannot prove the legacy producer has finished.
        pending.timeout.cancel(); pending.continuation.resume(throwing: error)
    }

    public func close() async {
        stopping = true
        let values = connections
        connections.removeAll()
        for (id, connection) in values {
            fail(machineId: id, epoch: connection.epoch, error: MachineCommandError.disconnected)
        }
        let active = Array(transports.values)
        for transport in active { transport.channel.close(promise: nil) }
        for transport in active { _ = try? await transport.finished.futureResult.get() }
    }

    public func sendAndAwaitAcknowledgement(
        machineId: String, command: MachineCommand, timeout: Duration = .seconds(10), requiredRuntime: String? = nil
    ) async throws -> MachineCommandReply {
        guard command.kind == .start || command.kind == .deliver else { throw MachineCommandError.noOutcomeContract }
        return try await send(machineId: machineId, command: command, stage: .acknowledgement, timeout: timeout, requiredRuntime: requiredRuntime)
    }

    public func sendAndAwaitOutcome(
        machineId: String, command: MachineCommand, timeout: Duration = .seconds(60),
        acknowledgementTimeout: Duration = .seconds(10), requiredRuntime: String? = nil
    ) async throws -> MachineCommandReply {
        guard command.kind == .start else { throw MachineCommandError.noOutcomeContract }
        return try await send(machineId: machineId, command: command, stage: .outcome, timeout: timeout, acknowledgementTimeout: acknowledgementTimeout, requiredRuntime: requiredRuntime)
    }

    /// A stop has no upstream ACK. Success here means only that its frame was
    /// written to this authenticated connection; lifecycle facts arrive later.
    public func sendStop(machineId: String, agentId: String, connectionEpochId: String) async throws {
        struct Stop: Encodable { let type = "agent:stop"; let agentId: String }
        guard !agentId.isEmpty else { throw MachineCommandError.invalidCommand }
        let data = try JSONEncoder().encode(Stop(agentId: agentId))
        let command = try MachineCommand(json: String(decoding: data, as: UTF8.self))
        try await sendControl(machineId: machineId, command: command, connectionEpochId: connectionEpochId)
    }

    /// Official two-field body. A successful local write is dispatched but the
    /// Computer sends no workspace-cleanup ACK, outcome or capability flag.
    public func sendWorkspaceReset(machineId: String, agentId: String, connectionEpochId: String) async throws {
        struct WorkspaceReset: Encodable { let type = "agent:reset-workspace"; let agentId: String }
        guard !agentId.isEmpty else { throw MachineCommandError.invalidCommand }
        let data = try JSONEncoder().encode(WorkspaceReset(agentId: agentId))
        let command = try MachineCommand(json: String(decoding: data, as: UTF8.self), expectedConnectionEpochId: connectionEpochId)
        try await sendControl(machineId: machineId, command: command, connectionEpochId: connectionEpochId)
    }

    public func sendControl(machineId: String, command: MachineCommand, connectionEpochId: String) async throws {
        guard command.kind == .stop || command.kind == .resetWorkspace else { throw MachineCommandError.unsupportedCommand }
        guard let connection = connections[machineId], connection.ready, connection.channel.isActive else {
            throw MachineCommandError.machineOffline
        }
        guard connection.epoch == connectionEpochId,
              command.connectionEpochId == nil || command.connectionEpochId == connectionEpochId else {
            throw MachineCommandError.disconnected
        }
        // Stops remain possible while runtime detection is pending, so a held
        // start can be cancelled. The ready frame must still advertise stop.
        if command.kind == .stop, durableIngress != nil, connection.daemonReady?.capabilities?.contains("agent:stop") != true {
            throw MachineCommandError.machineOffline
        }
        try Task.checkCancellation()
        guard connections[machineId]?.epoch == connectionEpochId, connection.channel.isActive else {
            throw MachineCommandError.disconnected
        }
        try await MachineCommandWebSocket.write(opcode: 1, payload: Array(command.json.utf8), channel: connection.channel).get()
        guard connections[machineId]?.epoch == connectionEpochId else { throw MachineCommandError.disconnected }
    }

    private func send(
        machineId: String, command: MachineCommand, stage: MachineCommandReply.Stage, timeout: Duration,
        acknowledgementTimeout: Duration? = nil, requiredRuntime: String? = nil
    ) async throws -> MachineCommandReply {
        guard let connection = connections[machineId], connection.ready, connection.channel.isActive else { throw MachineCommandError.machineOffline }
        if let expected = command.connectionEpochId, expected != connection.epoch { throw MachineCommandError.disconnected }
        if durableIngress != nil {
            guard let inventory = connection.daemonReady, inventory.hasCompleteInventory else {
                throw MachineCommandError.machineOffline
            }
            if let requiredRuntime, let wireRuntime = command.runtime, requiredRuntime != wireRuntime {
                throw MachineCommandError.runtimeUnavailable
            }
            guard let runtime = requiredRuntime ?? command.runtime, !runtime.isEmpty,
                  inventory.runtimes?.contains(runtime) == true else { throw MachineCommandError.runtimeUnavailable }
            let capability = command.kind == .start ? "agent:start" : "agent:deliver"
            guard inventory.capabilities?.contains(capability) == true else { throw MachineCommandError.unsupportedCommand }
        }
        try Task.checkCancellation()
        guard pending[machineId]?[command.id] == nil else { throw MachineCommandError.duplicatePendingCommand }
        let epoch = command.connectionEpochId ?? connection.epoch
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timer = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard !Task.isCancelled else { return }
                    self.failOne(machineId: machineId, id: command.id, epoch: epoch, error: MachineCommandError.timedOut)
                }
                let ackTimer: Task<Void, Never>?
                if let acknowledgementTimeout {
                    ackTimer = Task {
                        do { try await Task.sleep(for: acknowledgementTimeout) } catch { return }
                        guard !Task.isCancelled else { return }
                        self.failOne(machineId: machineId, id: command.id, epoch: epoch, error: MachineCommandError.timedOut)
                    }
                } else { ackTimer = nil }
                pending[machineId, default: [:]][command.id] = Pending(
                    epoch: epoch, command: command, stage: stage, continuation: continuation,
                    timeout: timer, acknowledgementTimeout: ackTimer
                )
                Task {
                    do {
                        guard self.connections[machineId]?.epoch == epoch, connection.channel.isActive else {
                            throw MachineCommandError.disconnected
                        }
                        try await MachineCommandWebSocket.write(opcode: 1, payload: Array(command.json.utf8), channel: connection.channel).get()
                    } catch {
                        self.failOne(machineId: machineId, id: command.id, epoch: epoch, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failOne(machineId: machineId, id: command.id, epoch: epoch, error: CancellationError()) }
        }
    }

    func receive(machineId: String, epoch: String, json: String) async throws {
        guard let connection = connections[machineId], connection.epoch == epoch, connection.channel.isActive else {
            throw MachineCommandError.disconnected
        }
        let payload = Data(json.utf8)
        struct Envelope: Decodable { let type: String }
        let type = try JSONDecoder().decode(Envelope.self, from: payload).type
        if let durableIngress {
            let context = MachineIngressContext(machineId: machineId, serverId: connection.serverId, connectionEpochId: epoch)
            let message = MachineIngressMessage(type: type, payload: payload)
            // A new ready invalidates the earlier inventory while its durable
            // running-agent reconciliation is pending or fails to commit.
            if type == "ready" {
                connections[machineId]?.daemonReady = nil
                connections[machineId]?.workspaceScanDaemonInstanceId = nil
            }
            let result: MachineIngressCommitResult
            do { result = try await durableIngress.onMessage(context, message) }
            catch { return } // No ACK; the same connection may replay the evidence.
            guard let current = connections[machineId], current.epoch == epoch, current.channel.isActive,
                  case .committed(let acknowledgement) = result else { return }
            if type == "ready" {
                connections[machineId]?.daemonReady = message.ready
                connections[machineId]?.workspaceScanDaemonInstanceId = message.ready?.daemonInstanceId
            }
            correlateQuery(machineId: machineId, epoch: epoch, payload: payload)
            if let fields = try? JSONDecoder().decode(MachineCommandFields.self, from: payload),
               (try? validateCorrelationFields(fields)) != nil {
                correlate(machineId: machineId, epoch: epoch, fields: fields, json: json)
            }
            if message.isOutcomeOutboxEntry, let acknowledgement {
                let data = try acknowledgement.encoded()
                // The callback may have suspended through a replacement. This
                // check is immediately before relay, with no intervening await.
                guard connections[machineId]?.epoch == epoch, current.channel.isActive else { return }
                try await MachineCommandWebSocket.write(opcode: 1, payload: Array(data), channel: current.channel).get()
            }
            return
        }
        let fields = try JSONDecoder().decode(MachineCommandFields.self, from: payload)
        try validateCorrelationFields(fields)
        if type == "ready" { connections[machineId]?.workspaceScanDaemonInstanceId = nil }
        if let commit { try await commit(machineId, json) }
        guard connections[machineId]?.epoch == epoch else { return }
        if type == "ready" { connections[machineId]?.workspaceScanDaemonInstanceId = fields.daemonInstanceId }
        correlateQuery(machineId: machineId, epoch: epoch, payload: payload)
        correlate(machineId: machineId, epoch: epoch, fields: fields, json: json)
        // Legacy callbacks preserve command correlation, but never authorize
        // outcome ACKs by virtue of raw payload fields or callback presence.
    }

    private func validateCorrelationFields(_ fields: MachineCommandFields) throws {
        if fields.type == "agent:start:ack" {
            guard fields.agentId != nil, fields.startDispatchId != nil,
                  ["queued", "starting", "running", "rebound"].contains(fields.queueState ?? ""),
                  let depth = fields.queueDepth, depth >= 0, let age = fields.queueAgeMs, age >= 0 else {
                throw MachineCommandError.protocolViolation
            }
        }
        if fields.type == "agent:process_spawned" || fields.type == "agent:start:outcome" {
            guard fields.agentId != nil, fields.launchId != nil, fields.daemonInstanceId != nil,
                  let seq = fields.clientSeq, seq >= 0 else { throw MachineCommandError.protocolViolation }
            if fields.type == "agent:process_spawned" {
                guard fields.processInstanceId != nil else { throw MachineCommandError.protocolViolation }
            } else {
                guard let result = fields.result,
                      (result.kind == "rebound" && result.processInstanceId != nil)
                        || (result.kind == "not_spawned" && result.reason != nil) else {
                    throw MachineCommandError.protocolViolation
                }
            }
        }
    }

    private func correlate(machineId: String, epoch: String, fields: MachineCommandFields, json: String) {
        if let values = pending[machineId] {
            for (id, value) in values where value.epoch == epoch && value.command.agentId == fields.agentId {
                let ack = (value.command.kind == .start && fields.type == "agent:start:ack" && fields.startDispatchId == id
                    && (fields.launchId == nil || fields.launchId == value.command.launchId))
                    || (value.command.kind == .deliver && fields.type == "agent:deliver:ack"
                        && fields.deliveryId == id && fields.seq == value.command.deliverySequence)
                let outcome = value.command.kind == .start
                    && (fields.type == "agent:process_spawned" || fields.type == "agent:start:outcome")
                    && (fields.launchId == value.command.launchId
                        || fields.supersededLaunchIds?.contains(value.command.launchId ?? "") == true)
                if ack { value.acknowledgementTimeout?.cancel() }
                if (ack && value.stage == .acknowledgement) || (outcome && value.stage == .outcome) {
                    pending[machineId]?.removeValue(forKey: id)
                    value.timeout.cancel(); value.acknowledgementTimeout?.cancel()
                    value.continuation.resume(returning: MachineCommandReply(commandId: id, stage: value.stage, json: json))
                } else if outcome && value.stage == .acknowledgement {
                    failOne(machineId: machineId, id: id, epoch: epoch, error: MachineCommandError.rejected(json))
                }
            }
        }
    }

    private func failOne(machineId: String, id: String, epoch: String, error: any Error) {
        guard let value = pending[machineId]?[id], value.epoch == epoch else { return }
        pending[machineId]?.removeValue(forKey: id)
        value.timeout.cancel(); value.acknowledgementTimeout?.cancel(); value.continuation.resume(throwing: error)
    }

    private func fail(machineId: String, epoch: String, error: any Error) {
        for (id, value) in pending[machineId] ?? [:] where value.epoch == epoch {
            failOne(machineId: machineId, id: id, epoch: epoch, error: error)
        }
        for (id, value) in pendingQueries[machineId] ?? [:] where value.epoch == epoch {
            failQuery(machineId: machineId, id: id, epoch: epoch, error: error)
        }
    }
}
