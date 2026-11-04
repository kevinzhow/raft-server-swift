import Testing
import RaftDaemonClient

private func kind(
    electron: Bool? = nil, sea: Bool? = nil, nodeRuntime: Bool? = nil,
    probe: (@Sendable () -> Bool?)? = nil
) -> NodeHostKind {
    NodeHostLaunchResolver.detectKind(.init(
        execIsElectron: electron, execIsSea: sea, hasNodeRuntime: nodeRuntime, seaProbe: probe
    ))
}

@Test func hostKindDistinguishesSeaFromNode() {
    #expect(kind(electron: false, sea: true) == .sea)
    #expect(kind(electron: false, sea: false) == .node)
    #expect(kind(electron: true, sea: false) == .electron)
    #expect(kind(electron: true, sea: true) == .electron)
}

@Test func hostKindNeverReportsNonElectronAsNodeWithoutCheckingSea() {
    #expect(kind(electron: false, sea: true) != .node, "a SEA host must never be classified as node")
}

@Test func unrecognisedHostIsUnknownNeverNode() {
    #expect(kind(electron: false, sea: false, nodeRuntime: false) == .unknown)
    #expect(kind(electron: false, sea: false, nodeRuntime: true) == .node)
}

@Test func seaHostFailsWithANamedCapabilityError() {
    do {
        _ = try NodeHostLaunchResolver.resolve(.init(
            env: [:], execPath: #"C:\Program Files\raft-computer.exe"#,
            kind: .init(execIsElectron: false, execIsSea: true)
        ))
        Issue.record("expected failure")
    } catch let error as NodeHostUnavailableError {
        #expect(error.kind == "node_host_unavailable")
        #expect(error.hostKind == .sea)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func unknownHostFailsClosedRatherThanTryingExecPath() {
    do {
        _ = try NodeHostLaunchResolver.resolve(.init(
            env: [:], execPath: "/opt/mystery",
            kind: .init(execIsElectron: false, execIsSea: false, hasNodeRuntime: false)
        ))
        Issue.record("expected failure")
    } catch let error as NodeHostUnavailableError {
        #expect(error.hostKind == .unknown)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func plainNodeHostIsUntouched() throws {
    let env = ["PATH": "/usr/bin", "EXISTING": "kept"]
    let launch = try NodeHostLaunchResolver.resolve(.init(
        env: env, execPath: "/usr/local/bin/node",
        kind: .init(execIsElectron: false, execIsSea: false, hasNodeRuntime: true)
    ))
    #expect(launch.command == "/usr/local/bin/node")
    #expect(launch.env == env)
    #expect(launch.env["ELECTRON_RUN_AS_NODE"] == nil, "plain Node must not gain the Electron flag")
}

@Test func electronGetsNodeModeAndKeepsTheEnvironment() throws {
    let launch = try NodeHostLaunchResolver.resolve(.init(
        env: ["PATH": "/usr/bin", "EXISTING": "kept"],
        execPath: "/Applications/Raft.app/Contents/MacOS/Raft",
        kind: .init(execIsElectron: true)
    ))
    #expect(launch.env["ELECTRON_RUN_AS_NODE"] == "1")
    #expect(launch.env["EXISTING"] == "kept")
}

@Test func realProbeRunsAndReturnsAUsableAnswer() {
    #expect(kind(electron: false) == .node, "a plain host must classify as node via the real probe")
    #expect(kind(electron: false, nodeRuntime: false) == .unknown)
}

@Test func probeThatCannotAnswerYieldsUnknownNeverNode() {
    #expect(kind(electron: false, nodeRuntime: true, probe: { nil }) == .unknown)
    #expect(kind(electron: false, nodeRuntime: true, probe: { false }) == .node)
    #expect(kind(electron: false, nodeRuntime: true, probe: { true }) == .sea)
}

@Test func probeSeparatesMissingModuleFromAProbeItCouldNotRun() {
    #expect(NodeHostLaunchResolver.seaDetected(requireModule: { _ in throw SeaProbeError.missingModule }) == false)
    #expect(NodeHostLaunchResolver.seaDetected(requireModule: { _ in throw SeaProbeError.unknownBuiltinModule }) == false)
    #expect(NodeHostLaunchResolver.seaDetected(requireModule: { _ in throw SeaProbeError.other }) == nil)
    #expect(NodeHostLaunchResolver.seaDetected(requireModule: { _ in
        .init(isSea: { throw SeaProbeError.other })
    }) == nil)
    #expect(NodeHostLaunchResolver.seaDetected(requireModule: { _ in .init(isSea: { true }) }) == true)
    #expect(NodeHostLaunchResolver.seaDetected(requireModule: { _ in .init(isSea: { false }) }) == false)
}
