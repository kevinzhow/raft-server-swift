import Foundation

/// The three shapes a shipped `execPath` takes: `node` (a real Node binary),
/// `electron` (the Electron executable; can be told to behave as Node via
/// `ELECTRON_RUN_AS_NODE=1`), and `sea` (a single-file executable where the
/// path IS the bundled app; there is no Node mode inside a SEA). `unknown`
/// exists because the list is enumerated, not provably exhaustive; an
/// unrecognised host must never inherit `node`'s behaviour. Ported from the
/// upstream daemon driver.
public enum NodeHostKind: String, Sendable, Equatable {
    case node, electron, sea, unknown
}

/// Errors a `node:sea` probe can raise; the port models the two "cannot be a
/// SEA" codes explicitly instead of matching error strings.
public enum SeaProbeError: Error, Sendable, Equatable {
    case missingModule
    case unknownBuiltinModule
    case other
}

public struct NodeHostKindOptions: Sendable {
    public var execIsElectron: Bool?
    public var execIsSea: Bool?
    public var hasNodeRuntime: Bool?
    public var seaProbe: (@Sendable () -> Bool?)?

    public init(
        execIsElectron: Bool? = nil, execIsSea: Bool? = nil,
        hasNodeRuntime: Bool? = nil, seaProbe: (@Sendable () -> Bool?)? = nil
    ) {
        self.execIsElectron = execIsElectron
        self.execIsSea = execIsSea
        self.hasNodeRuntime = hasNodeRuntime
        self.seaProbe = seaProbe
    }
}

public struct NodeHostLaunchOptions: Sendable {
    public var env: [String: String]
    public var execPath: String
    public var kind: NodeHostKindOptions
    public init(env: [String: String], execPath: String, kind: NodeHostKindOptions) {
        self.env = env
        self.execPath = execPath
        self.kind = kind
    }
}

public struct NodeHostLaunch: Sendable, Equatable {
    public var command: String
    public var env: [String: String]
    public init(command: String, env: [String: String]) {
        self.command = command
        self.env = env
    }
}

public final class NodeHostUnavailableError: Error, @unchecked Sendable, CustomStringConvertible {
    public let kind = "node_host_unavailable"
    public let hostKind: NodeHostKind
    public let description: String
    public init(hostKind: NodeHostKind) {
        self.hostKind = hostKind
        if hostKind == .sea {
            self.description = "This Computer is a single-file build, which has no Node mode and cannot execute a JavaScript CLI entry directly. A separate Node host is required."
        } else {
            self.description = "Cannot determine how to run a JavaScript CLI entry on this host (host_kind=\(hostKind.rawValue))."
        }
    }
}

public enum NodeHostLaunchResolver {
    public typealias RequireModule = @Sendable (String) throws -> SeaModule

    public struct SeaModule {
        public var isSea: @Sendable () throws -> Bool
        public init(isSea: @escaping @Sendable () throws -> Bool) {
            self.isSea = isSea
        }
    }

    /// Ask the runtime whether it is a SEA. `nil` means "could not ask", which
    /// is NOT the same as `false`; only a missing builtin module is real
    /// evidence that this runtime cannot be a SEA.
    public static func seaDetected(requireModule: RequireModule = { _ in throw SeaProbeError.missingModule }) -> Bool? {
        let module: SeaModule
        do {
            module = try requireModule("node:sea")
        } catch let error as SeaProbeError {
            switch error {
            case .missingModule, .unknownBuiltinModule: return false
            case .other: return nil
            }
        } catch {
            return nil
        }
        do {
            return try module.isSea()
        } catch {
            return nil
        }
    }

    /// Electron is checked first because an Electron build is never a SEA and
    /// its signal is the cheaper, more certain one.
    public static func detectKind(_ options: NodeHostKindOptions = .init()) -> NodeHostKind {
        let execIsElectron = options.execIsElectron ?? isElectronHost()
        if execIsElectron { return .electron }

        let execIsSea: Bool? = options.execIsSea
            ?? (options.seaProbe ?? { seaDetected() })()
        if execIsSea == true { return .sea }
        // "I could not ask" is not evidence of "not a SEA".
        if execIsSea == nil { return .unknown }

        // `node` is a positive determination, never the residue of two failed checks.
        let hasNodeRuntime = options.hasNodeRuntime ?? hasNodeSignal()
        return hasNodeRuntime ? .node : .unknown
    }

    /// Swift hosts are not Electron and not Node; the environment signals are
    /// only honoured when present, so tests inject them explicitly.
    static func isElectronHost() -> Bool {
        ProcessInfo.processInfo.environment["ELECTRON_RUN_AS_NODE"] != nil
    }

    static func hasNodeSignal() -> Bool {
        // The shipped daemon host has a Node runtime; a host without one must
        // say so explicitly (injected as `hasNodeRuntime: false`).
        true
    }

    /// Run a JavaScript CLI entry through the current Node-capable host.
    public static func resolve(_ options: NodeHostLaunchOptions) throws -> NodeHostLaunch {
        switch detectKind(options.kind) {
        case .electron:
            var env = options.env
            env["ELECTRON_RUN_AS_NODE"] = "1"
            return NodeHostLaunch(command: options.execPath, env: env)
        case .node:
            return NodeHostLaunch(command: options.execPath, env: options.env)
        case .sea, .unknown:
            throw NodeHostUnavailableError(hostKind: detectKind(options.kind))
        }
    }
}
