import Foundation
import Crypto

/// Platform-owned durable storage for one authenticated Computer/Server pair.
/// Apps receive only a read/write capability: never the root, an absolute path,
/// or authority to construct a sibling scope. Scope is
/// `<home>/app-storage/v1/<machine>/<server>/<app>/{computer|agents/<agent>}/state.json`.
/// Ported from the upstream daemon storage.
public enum ScopedAppStorage {
    public static let safeSegmentPattern = "^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$"

    public struct FailureEvent: Sendable, Equatable {
        public var operation: String
        public var store: String
        public var appId: String
        public var serverId: String
        public var writerEpoch: String
        public var outcome: String
        public var reason: String
        public var failureInstanceId: String?
        public var observation: String?
        public init(
            operation: String, store: String, appId: String, serverId: String, writerEpoch: String,
            outcome: String, reason: String, failureInstanceId: String? = nil, observation: String? = nil
        ) {
            self.operation = operation
            self.store = store
            self.appId = appId
            self.serverId = serverId
            self.writerEpoch = writerEpoch
            self.outcome = outcome
            self.reason = reason
            self.failureInstanceId = failureInstanceId
            self.observation = observation
        }
        public var description: String {
            "\(operation)/\(store) app=\(appId) outcome=\(outcome) reason=\(reason)"
        }
    }

    public struct Owner: Sendable {
        public var machineId: String
        public var serverId: String
        public init(machineId: String, serverId: String) {
            self.machineId = machineId
            self.serverId = serverId
        }
    }

    public struct Scope: Sendable {
        public var appId: String
        public var agentId: String?
        public init(appId: String, agentId: String? = nil) {
            self.appId = appId
            self.agentId = agentId
        }
    }

    public enum QuarantineResult: String, Sendable, Equatable {
        case absent, quarantined
    }

    public struct StorageError: Error, CustomStringConvertible {
        public let description: String
        public let code: String?
        public init(_ description: String, code: String? = nil) {
            self.description = description
            self.code = code
        }
    }

    public static func requireSafeSegment(_ kind: String, _ value: String) throws -> String {
        let regex = try! NSRegularExpression(pattern: safeSegmentPattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard regex.firstMatch(in: value, range: range) != nil, value != ".", value != ".." else {
            throw StorageError("scoped app storage \(kind) is invalid")
        }
        return value
    }

    public static func classifyFailureReason(code: String?) -> String {
        guard let code else { return "unknown" }
        if code == "EACCES" || code == "EPERM" { return "permission_denied" }
        if code == "ENOENT" { return "path_missing" }
        if code == "EAGAIN" || code == "EBUSY" || code == "EEXIST" { return "lock_contention" }
        if code.hasPrefix("E") { return "storage_io" }
        return "unknown"
    }

    static func classify(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(ENOENT): return "path_missing"
            case Int(EACCES), Int(EPERM): return "permission_denied"
            case Int(EAGAIN), Int(EBUSY), Int(EEXIST): return "lock_contention"
            case Int(ENOTDIR), Int(EIO), Int(EROFS), Int(ENOSPC): return "storage_io"
            default: return "storage_io"
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError: return "path_missing"
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "permission_denied"
            default: return "storage_io"
            }
        }
        return "unknown"
    }

    public final class Capability: @unchecked Sendable {
        private let filePath: String
        private let appId: String
        private let factory: Factory
        private var lastReadGeneration: String?
        private var lastReportedGeneration: [String: String] = [:]

        init(filePath: String, appId: String, factory: Factory) {
            self.filePath = filePath
            self.appId = appId
            self.factory = factory
        }

        public func assertActive() throws {
            try factory.requireActive(appId: appId)
        }

        public func readText() throws -> String? {
            try factory.requireActive(appId: appId)
            do {
                let read = try Self.readTextWithGeneration(filePath)
                lastReadGeneration = read.generation
                return read.text
            } catch {
                factory.emitFailure(operation: "read", store: "app_state", appId: appId,
                                    outcome: "failed", reason: Self.factoryReason(error))
                throw error
            }
        }

        public func writeTextAtomic(_ contents: String) throws {
            try factory.requireActive(appId: appId)
            do {
                try Self.writeAtomic(filePath, contents)
                lastReadGeneration = nil
            } catch {
                factory.emitFailure(operation: "write", store: "app_state", appId: appId,
                                    outcome: "failed", reason: Self.factoryReason(error))
                throw error
            }
        }

        public func reportDataFailure(_ reason: String) throws {
            try factory.requireActive(appId: appId)
            let failureInstanceId = lastReadGeneration ?? Self.sha256Hex("unread:\(UUID().uuidString)")
            lastReadGeneration = failureInstanceId
            let observation = lastReportedGeneration[reason] == failureInstanceId ? "level" : "edge"
            lastReportedGeneration[reason] = failureInstanceId
            factory.emitFailure(
                operation: "decode", store: "app_state", appId: appId, outcome: "failed",
                reason: reason, failureInstanceId: failureInstanceId, observation: observation
            )
        }

        static func factoryReason(_ error: Error) -> String {
            if let storage = error as? StorageError, let code = storage.code {
                return classifyFailureReason(code: code)
            }
            return ScopedAppStorage.classify(error)
        }

        static func sha256Hex(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        static func readTextWithGeneration(_ filePath: String) throws -> (text: String?, generation: String?) {
            guard FileManager.default.fileExists(atPath: filePath) else { return (nil, nil) }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath) else {
                throw StorageError("scoped app storage read failed", code: "EIO")
            }
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let generation = sha256Hex("\(inode):\(size):\(modified)")
            let text = try String(contentsOfFile: filePath, encoding: .utf8)
            return (text, generation)
        }

        static func writeAtomic(_ filePath: String, _ contents: String) throws {
            let directory = (filePath as NSString).deletingLastPathComponent
            do {
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw StorageError("scoped app storage mkdir failed", code: Self.posixCode(error) ?? "EIO")
            }
            let tempPath = directory + "/." + (filePath as NSString).lastPathComponent + ".\(UUID().uuidString).tmp"
            do {
                try contents.write(toFile: tempPath, atomically: false, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempPath)
                if FileManager.default.fileExists(atPath: filePath) {
                    try FileManager.default.removeItem(atPath: filePath)
                }
                try FileManager.default.moveItem(atPath: tempPath, toPath: filePath)
            } catch {
                try? FileManager.default.removeItem(atPath: tempPath)
                throw StorageError("scoped app storage write failed", code: Self.posixCode(error) ?? "EIO")
            }
        }

        static func posixCode(_ error: Error) -> String? {
            let nsError = error as NSError
            guard nsError.domain == NSPOSIXErrorDomain else { return nil }
            switch nsError.code {
            case Int(ENOENT): return "ENOENT"
            case Int(EACCES): return "EACCES"
            case Int(EPERM): return "EPERM"
            case Int(EAGAIN): return "EAGAIN"
            case Int(EBUSY): return "EBUSY"
            case Int(EEXIST): return "EEXIST"
            case Int(ENOTDIR): return "ENOTDIR"
            default: return "EIO"
            }
        }
    }

    public final class Factory: @unchecked Sendable {
        let slockHome: String
        let machineId: String
        let serverId: String
        let writerEpoch: String
        let onFailure: (@Sendable (FailureEvent) -> Void)?
        private let lock = NSLock()
        private var revoked = false
        private let ownerRoot: String

        public init(
            slockHome: String, owner: Owner, writerEpoch: String? = nil,
            onFailure: (@Sendable (FailureEvent) -> Void)? = nil
        ) throws {
            self.slockHome = URL(fileURLWithPath: slockHome).standardizedFileURL.path
            self.machineId = try ScopedAppStorage.requireSafeSegment("machine id", owner.machineId)
            self.serverId = try ScopedAppStorage.requireSafeSegment("server id", owner.serverId)
            self.writerEpoch = try ScopedAppStorage.requireSafeSegment("writer epoch", writerEpoch ?? UUID().uuidString)
            self.onFailure = onFailure
            self.ownerRoot = self.slockHome + "/app-storage/v1/" + self.machineId + "/" + self.serverId
        }

        func requireActive(appId: String) throws {
            let isRevoked = lock.withLock { revoked }
            guard !isRevoked else {
                emitFailure(operation: "access", store: "app_state", appId: appId,
                            outcome: "denied", reason: "capability_revoked")
                throw ScopedAppStorage.StorageError("scoped app storage capability is revoked")
            }
        }

        func emitFailure(
            operation: String, store: String, appId: String, outcome: String, reason: String,
            failureInstanceId: String? = nil, observation: String? = nil
        ) {
            onFailure?(ScopedAppStorage.FailureEvent(
                operation: operation, store: store, appId: appId, serverId: serverId,
                writerEpoch: writerEpoch, outcome: outcome, reason: reason,
                failureInstanceId: failureInstanceId, observation: observation
            ))
        }

        public func open(_ scope: Scope) throws -> Capability {
            let appId = try ScopedAppStorage.requireSafeSegment("app id", scope.appId)
            try requireActive(appId: appId)
            let filePath: String
            if let agentId = scope.agentId {
                let safeAgent = try ScopedAppStorage.requireSafeSegment("agent id", agentId)
                filePath = ownerRoot + "/" + appId + "/agents/" + safeAgent + "/state.json"
            } else {
                filePath = ownerRoot + "/" + appId + "/computer/state.json"
            }
            return Capability(filePath: filePath, appId: appId, factory: self)
        }

        public func quarantineLegacyFile(relativePath: String, appId rawAppId: String) throws -> QuarantineResult {
            let appId = try ScopedAppStorage.requireSafeSegment("app id", rawAppId)
            try requireActive(appId: appId)
            let portable = relativePath.replacingOccurrences(of: "\\", with: "/")
            if relativePath.isEmpty || portable.hasPrefix("/") || portable.hasPrefix("\\") {
                throw ScopedAppStorage.StorageError("scoped app storage legacy path is invalid")
            }
            let normalized = ScopedAppStorage.normalizeRelative(portable)
            if normalized == ".." || normalized.hasPrefix("../") {
                throw ScopedAppStorage.StorageError("scoped app storage legacy path escapes root")
            }
            let sourcePath = slockHome + "/" + normalized
            guard FileManager.default.fileExists(atPath: sourcePath) else { return .absent }
            let leaf = (normalized as NSString).lastPathComponent
            let quarantineRoot = slockHome + "/app-storage-quarantine/v1/unscoped"
            let destinationPath = quarantineRoot + "/" + UUID().uuidString + "-" + leaf
            do {
                try FileManager.default.createDirectory(
                    atPath: quarantineRoot, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.moveItem(atPath: sourcePath, toPath: destinationPath)
                return .quarantined
            } catch {
                if !FileManager.default.fileExists(atPath: sourcePath) { return .absent }
                emitFailure(operation: "legacy_quarantine", store: "legacy_unscoped", appId: appId,
                            outcome: "failed", reason: Capability.factoryReason(error))
                throw error
            }
        }

        public func revoke() {
            lock.withLock { revoked = true }
        }
    }

    static func normalizeRelative(_ value: String) -> String {
        var parts: [String] = []
        for component in value.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if parts.last == ".." || parts.isEmpty { parts.append("..") } else { parts.removeLast() }
            } else {
                parts.append(String(component))
            }
        }
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
