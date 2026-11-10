import Crypto
import Foundation

public struct PersistentMachineCommand: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case start, deliver }
    public let kind: Kind
    public let id: String
    public let agentId: String
    public let launchId: String?
    public let deliverySequence: Int?
    public let connectionEpochId: String?
    public let json: String
    public init(json: String) throws {
        guard json.utf8.count <= 1_048_576 else { throw PersistentDaemonError.protocolViolation }
        struct Fields: Decodable {
            let type: String; let agentId: String?
            let startDispatchId: String?; let launchId: String?; let deliveryId: String?; let seq: Int?; let connectionEpochId: String?
        }
        let fields = try JSONDecoder().decode(Fields.self, from: Data(json.utf8))
        guard let agent = fields.agentId, !agent.isEmpty else { throw PersistentDaemonError.protocolViolation }
        switch fields.type {
        case "agent:start":
            guard let id = fields.startDispatchId, !id.isEmpty, let launch = fields.launchId, !launch.isEmpty else {
                throw PersistentDaemonError.protocolViolation
            }
            kind = .start; self.id = id; launchId = launch; deliverySequence = nil
        case "agent:deliver":
            guard let id = fields.deliveryId, !id.isEmpty, fields.seq != nil else { throw PersistentDaemonError.protocolViolation }
            kind = .deliver; self.id = id; launchId = nil; deliverySequence = fields.seq
        default: throw PersistentDaemonError.unsupportedExecution
        }
        agentId = agent; connectionEpochId = fields.connectionEpochId; self.json = json
    }
}

public enum PersistentCommandClaim: Sendable, Equatable {
    case acquired
    case completed(frames: [String])
    /// The previous process may have performed the effect. Never execute again automatically.
    case indeterminate
}

/// Implementations must atomically bind machine+command ID to the exact request,
/// persist each outgoing frame BEFORE it reaches the socket, and retain claims
/// after restart. Server PG outbox integration uses the same command identity.
public protocol PersistentCommandReceipting: Sendable {
    func claim(machineId: String, command: PersistentMachineCommand) async throws -> PersistentCommandClaim
    func record(machineId: String, commandId: String, frame: String, terminal: Bool) async throws
    func recordOutcomeAcknowledgement(json: String) async throws
}

/// A runtime owner must emit real upstream ACK/outcome messages. Transport and
/// receipt code cannot substitute a process, CLI provider, or successful result.
public protocol PersistentMachineCommandExecuting: Sendable {
    func execute(
        _ command: PersistentMachineCommand,
        emit: @escaping @Sendable (_ upstreamJSON: String, _ terminal: Bool) async throws -> Void
    ) async throws
}

public struct PersistentMachineCommandReceiver: Sendable {
    private let receipts: any PersistentCommandReceipting
    private let executor: any PersistentMachineCommandExecuting
    public init(receipts: any PersistentCommandReceipting, executor: any PersistentMachineCommandExecuting) {
        self.receipts = receipts; self.executor = executor
    }

    public func receive(json: String, session: PersistentDaemonSession) async throws {
        struct TypeField: Decodable { let type: String }
        if try JSONDecoder().decode(TypeField.self, from: Data(json.utf8)).type == "agent:outcome:ack" {
            try await receipts.recordOutcomeAcknowledgement(json: json); return
        }
        let command = try PersistentMachineCommand(json: json)
        if let epoch = command.connectionEpochId, epoch != session.handshake.context.connectionEpochId {
            throw PersistentDaemonError.protocolViolation
        }
        let machineId = session.handshake.context.machineId
        switch try await receipts.claim(machineId: machineId, command: command) {
        case .completed(let frames):
            for frame in frames { try await session.send(json: frame) }
        case .indeterminate: throw PersistentDaemonError.receiptIndeterminate
        case .acquired:
            try await executor.execute(command) { frame, terminal in
                try Self.validate(frame: frame, command: command, terminal: terminal)
                try await receipts.record(machineId: machineId, commandId: command.id, frame: frame, terminal: terminal)
                try await session.send(json: frame)
            }
        }
    }

    private static func validate(frame: String, command: PersistentMachineCommand, terminal: Bool) throws {
        struct Fields: Decodable {
            let type: String; let agentId: String?; let launchId: String?; let startDispatchId: String?
            let deliveryId: String?; let supersededLaunchIds: [String]?; let seq: Int?
            let daemonInstanceId: String?; let clientSeq: Int?
        }
        let value = try JSONDecoder().decode(Fields.self, from: Data(frame.utf8))
        guard value.agentId == command.agentId else { throw PersistentDaemonError.protocolViolation }
        switch command.kind {
        case .start:
            if terminal {
                guard ["agent:process_spawned", "agent:start:outcome"].contains(value.type),
                      value.launchId == command.launchId || value.supersededLaunchIds?.contains(command.launchId ?? "") == true,
                      value.daemonInstanceId != nil, value.clientSeq != nil else { throw PersistentDaemonError.protocolViolation }
            } else {
                guard value.type == "agent:start:ack", value.startDispatchId == command.id else {
                    throw PersistentDaemonError.protocolViolation
                }
            }
        case .deliver:
            guard terminal, value.type == "agent:deliver:ack", value.deliveryId == command.id, value.seq == command.deliverySequence else {
                throw PersistentDaemonError.protocolViolation
            }
        }
    }
}

/// Actual disk receipts for a single locked daemon process. Atomic replacement
/// plus file synchronization persists receipts; directory/power-loss guarantees
/// and the server PG outbox remain deployment integration responsibilities.
/// In-flight records after restart are indeterminate, not replay permission.
public actor PersistentCommandFileReceipts: PersistentCommandReceipting {
    private struct Record: Codable {
        let machineId: String
        let commandId: String
        let requestHash: String
        var frames: [String]
        var terminal: Bool
    }
    private let directory: URL
    private let capacity: Int
    private var entries: Int

    public init(directory: URL, capacity: Int = 100_000) throws {
        guard directory.isFileURL, capacity > 0 else { throw PersistentDaemonError.invalidURL }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw PersistentDaemonError.invalidURL }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        self.directory = directory; self.capacity = capacity
        entries = try FileManager.default.contentsOfDirectory(atPath: directory.path).count
    }

    public func claim(machineId: String, command: PersistentMachineCommand) throws -> PersistentCommandClaim {
        let path = location(machineId: machineId, commandId: command.id)
        let digest = Self.hash(command.json)
        if FileManager.default.fileExists(atPath: path.path) {
            let record = try load(path)
            guard record.machineId == machineId, record.commandId == command.id, record.requestHash == digest else {
                throw PersistentDaemonError.receiptConflict
            }
            return record.terminal ? .completed(frames: record.frames) : .indeterminate
        }
        guard entries < capacity else { throw PersistentDaemonError.receiptIndeterminate }
        try store(Record(machineId: machineId, commandId: command.id, requestHash: digest, frames: [], terminal: false), at: path)
        entries += 1
        return .acquired
    }

    public func record(machineId: String, commandId: String, frame: String, terminal: Bool) throws {
        let path = location(machineId: machineId, commandId: commandId)
        var value = try load(path)
        guard value.machineId == machineId, value.commandId == commandId, !value.terminal,
              value.frames.count < 32, frame.utf8.count <= PersistentWebSocket.maximumMessageBytes else {
            throw PersistentDaemonError.receiptConflict
        }
        value.frames.append(frame); value.terminal = terminal
        try store(value, at: path)
    }

    public func recordOutcomeAcknowledgement(json: String) throws {
        struct Ack: Decodable { let type: String; let agentId: String; let daemonInstanceId: String?; let clientSeq: Int?; let gapId: String? }
        let ack = try JSONDecoder().decode(Ack.self, from: Data(json.utf8))
        guard ack.type == "agent:outcome:ack", (ack.daemonInstanceId != nil && ack.clientSeq != nil) || ack.gapId != nil else {
            throw PersistentDaemonError.protocolViolation
        }
        let path = directory.appendingPathComponent("ack-\(Self.hash(json)).json")
        if FileManager.default.fileExists(atPath: path.path) { return }
        guard entries < capacity else { throw PersistentDaemonError.receiptIndeterminate }
        try durableWrite(Data(json.utf8), at: path); entries += 1
    }

    private func location(machineId: String, commandId: String) -> URL {
        directory.appendingPathComponent(Self.hash(machineId + "\u{0}" + commandId) + ".json")
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func load(_ url: URL) throws -> Record {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard (size?.intValue ?? Int.max) <= 34 * PersistentWebSocket.maximumMessageBytes else {
            throw PersistentDaemonError.receiptIndeterminate
        }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }
    private func store(_ value: Record, at url: URL) throws {
        try durableWrite(JSONEncoder().encode(value), at: url)
    }
    private func durableWrite(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
