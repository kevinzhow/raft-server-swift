import Foundation

/// Legacy daemon keys that a Computer already adopted: starting raft-daemon
/// with the migrated key must refuse with precise cleanup and restart guidance
/// instead of racing the Computer for the connection. Ported from upstream.
public struct LegacyDaemonSupervisorGuidance: Sendable, Equatable {
    public var kind: String
    public var cleanupCommands: [String]
    public var detail: String

    public init(kind: String, cleanupCommands: [String], detail: String) {
        self.kind = kind
        self.cleanupCommands = cleanupCommands
        self.detail = detail
    }
}

public struct ComputerMigrationMatch: Sendable, Equatable {
    public var attachmentPath: String
    public var serverId: String
    public var serverSlug: String?
    public var serverMachineId: String?

    public init(attachmentPath: String, serverId: String, serverSlug: String? = nil, serverMachineId: String? = nil) {
        self.attachmentPath = attachmentPath
        self.serverId = serverId
        self.serverSlug = serverSlug
        self.serverMachineId = serverMachineId
    }
}

public enum LegacyDaemonSupervisorFallbacks {
    public static let commands: [String] = [
        "PM2: pm2 delete <legacy-daemon-app-name> && pm2 save",
        "systemd: systemctl --user disable --now <legacy-daemon-unit>.service",
        "launchd: launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/<legacy-daemon-label>.plist && rm -f ~/Library/LaunchAgents/<legacy-daemon-label>.plist",
    ]
}

public struct LegacyDaemonKeyAdoptedByComputerError: Error, CustomStringConvertible, Equatable {
    public let code = "LEGACY_DAEMON_KEY_ADOPTED_BY_COMPUTER"
    public let attachmentPath: String
    public let serverId: String
    public let description: String

    public init(match: ComputerMigrationMatch, supervisor: LegacyDaemonSupervisorGuidance?) {
        let serverDisplay = match.serverSlug.map { "/\($0)" } ?? match.serverId
        let startCommand = match.serverSlug.map { "raft-computer start /\($0)" } ?? "raft-computer start"
        let statusCommand = match.serverSlug.map { "raft-computer status /\($0)" } ?? "raft-computer status"
        let guidance: String
        if let supervisor {
            guidance = supervisor.detail
                + "\nRemove the old supervisor entry so it cannot auto-restart:\n"
                + supervisor.cleanupCommands.map { "  \($0)" }.joined(separator: "\n")
        } else {
            guidance = "If a process manager keeps restarting the old daemon, remove the entry you configured:\n"
                + LegacyDaemonSupervisorFallbacks.commands.map { "  \($0)" }.joined(separator: "\n")
        }
        self.attachmentPath = match.attachmentPath
        self.serverId = match.serverId
        self.description = "Legacy Raft daemon startup refused: this machine key was already migrated to Raft Computer for \(serverDisplay).\n"
            + "Raft Computer now owns this connection; do not restart raft-daemon with the migrated key.\n"
            + "\(guidance)\n"
            + "Then start and verify Raft Computer:\n  \(startCommand)\n  \(statusCommand)"
    }
}
