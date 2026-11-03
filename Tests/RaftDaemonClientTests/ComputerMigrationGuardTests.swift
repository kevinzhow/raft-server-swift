import Testing
import RaftDaemonClient

private let match = ComputerMigrationMatch(
    attachmentPath: "/tmp/runner.state.json",
    serverId: "11111111-1111-4111-8111-111111111111",
    serverSlug: "alpha"
)

@Test func migrationGuardErrorGivesPreciseDetectedSupervisorCleanupAndComputerCommands() {
    let error = LegacyDaemonKeyAdoptedByComputerError(
        match: match,
        supervisor: LegacyDaemonSupervisorGuidance(
            kind: "pm2",
            cleanupCommands: ["pm2 delete 'legacy-daemon'", "pm2 save"],
            detail: "PM2 app \"legacy-daemon\" is supervising this legacy daemon."
        )
    )
    #expect(error.description.hasPrefix("Legacy Raft daemon startup refused:"))
    #expect(error.description.contains("already migrated to Raft Computer for /alpha"))
    #expect(error.description.contains("PM2 app \"legacy-daemon\" is supervising"))
    #expect(error.description.contains("pm2 delete 'legacy-daemon'"))
    #expect(error.description.contains("pm2 save"))
    #expect(error.description.contains("raft-computer start /alpha"))
    #expect(error.description.contains("raft-computer status /alpha"))
    #expect(error.code == "LEGACY_DAEMON_KEY_ADOPTED_BY_COMPUTER")
}

@Test func migrationGuardErrorGivesPm2SystemdAndLaunchdFallbacksWithoutDetection() {
    let error = LegacyDaemonKeyAdoptedByComputerError(match: match, supervisor: nil)
    #expect(error.description.contains("PM2: pm2 delete <legacy-daemon-app-name> && pm2 save"))
    #expect(error.description.contains("systemd: systemctl --user disable --now <legacy-daemon-unit>.service"))
    #expect(error.description.contains("launchd: launchctl bootout gui/$(id -u)"))
    #expect(error.description.contains("do not restart raft-daemon with the migrated key"))
}
