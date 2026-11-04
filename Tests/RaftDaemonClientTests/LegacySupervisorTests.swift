import Foundation
import Testing
import RaftDaemonClient

private func probe(
    platform: String = "linux", env: [String: String] = [:],
    execFile: @escaping @Sendable (String, [String]) -> String? = { file, args in
        if file == "ps", args.count > 1, args[1] == "ppid=" { return "1\n" }
        return nil
    },
    readFile: @escaping @Sendable (String) -> String? = { _ in nil }
) -> LegacyDaemonSupervisorProbe {
    .init(pid: 42, platform: platform, env: env, execFile: execFile, readFile: readFile)
}

@Test func pm2DeleteGuidanceIsExact() {
    let result = LegacySupervisor.detect(probe(
        env: ["PM2_HOME": "/tmp/pm2"],
        execFile: { file, args in
            if file == "ps", args.count > 1, args[1] == "ppid=" { return "1\n" }
            if file == "pm2", args.first == "jlist" {
                return #"[{"name":"legacy daemon","pid":42}]"#
            }
            return nil
        }
    ))
    #expect(result == .init(
        kind: "pm2",
        cleanupCommands: ["pm2 delete 'legacy daemon'", "pm2 save"],
        detail: #"PM2 app "legacy daemon" is supervising this legacy daemon."#
    ))
}

@Test func pm2AppNamesAreQuoted() {
    let result = LegacySupervisor.detect(probe(
        env: ["pm_id": "0"],
        execFile: { file, args in
            if file == "ps", args.count > 1, args[1] == "ppid=" { return "1\n" }
            if file == "pm2" { return #"[{"name":"legacy's daemon","pid":42}]"# }
            return nil
        }
    ))
    #expect(result?.cleanupCommands.first == #"pm2 delete 'legacy'\''s daemon'"#)
}

@Test func userSystemdUnitIsResolvedFromCgroup() {
    let result = LegacySupervisor.detect(probe(
        readFile: { file in
            file == "/proc/42/cgroup"
                ? "0::/user.slice/user-1000.slice/user@1000.service/app.slice/raft-daemon.service\n"
                : nil
        }
    ))
    #expect(result == .init(
        kind: "systemd",
        cleanupCommands: ["systemctl --user disable --now 'raft-daemon.service'"],
        detail: #"systemd unit "raft-daemon.service" is supervising this legacy daemon."#
    ))
}

@Test func launchdLabelIsResolved() {
    let result = LegacySupervisor.detect(probe(platform: "darwin", env: ["XPC_SERVICE_NAME": "com.botiverse.raft-daemon"]))
    #expect(result == .init(
        kind: "launchd",
        cleanupCommands: [
            "launchctl bootout gui/$(id -u)/'com.botiverse.raft-daemon'",
            "rm -f ~/Library/LaunchAgents/'com.botiverse.raft-daemon.plist'",
        ],
        detail: #"launchd job "com.botiverse.raft-daemon" is supervising this legacy daemon."#
    ))
}

@Test func noSupervisorEvidenceReturnsNilAndDoesNotStartPm2() {
    final class Flag: @unchecked Sendable { var called = false }
    let flag = Flag()
    let result = LegacySupervisor.detect(probe(
        execFile: { file, args in
            if file == "pm2" { flag.called = true }
            if file == "ps", args.count > 1, args[1] == "ppid=" { return "1\n" }
            return nil
        }
    ))
    #expect(result == nil)
    #expect(flag.called == false, "PM2 must not be started just to probe an unrelated daemon")
}

@Test func ordinarySystemdUserSessionCgroupIsIgnored() {
    let result = LegacySupervisor.detect(probe(
        execFile: { file, args in
            if file == "ps", args.count > 1, args[1] == "ppid=" {
                return args.count > 3 && args[3] == "42" ? "9\n" : "1\n"
            }
            if file == "ps", args.count > 1, args[1] == "command=" {
                return "/usr/lib/systemd/systemd --user\n"
            }
            return nil
        },
        readFile: { _ in
            "0::/user.slice/user-1000.slice/user@1000.service/app.slice/vte-spawn.scope\n"
        }
    ))
    #expect(result == nil)
}
