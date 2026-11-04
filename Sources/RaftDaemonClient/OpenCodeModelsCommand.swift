import Foundation

/// The OpenCode model listing through the injected probe-child runner, plus the
/// matching synchronous path. Both resolve the same Windows executable, pass
/// the same args (2.x ≥ 2.0.27 wants `--standalone`) and map failures alike;
/// an abort is never turned into a mapped failure. Ported from the upstream
/// daemon probe driver.
public struct ProbeCleanup: Sendable, Equatable {
    public var childExited: Bool
    public var waitedMs: Int?
    public init(childExited: Bool, waitedMs: Int? = nil) {
        self.childExited = childExited
        self.waitedMs = waitedMs
    }
}

public final class ProbeChildError: Error, @unchecked Sendable {
    public let message: String
    public var code: String?
    public var status: Int?
    public var cleanup: ProbeCleanup?
    public init(_ message: String, code: String? = nil, status: Int? = nil, cleanup: ProbeCleanup? = nil) {
        self.message = message
        self.code = code
        self.status = status
        self.cleanup = cleanup
    }
}

public struct ProbeChildOptions: Sendable {
    public var timeoutMs: Int
    public var shell: Bool
    public var env: [String: String]
}

public struct ProbeChildOutput: Sendable {
    public var stdout: String
    public var stderr: String

    public init(stdout: String, stderr: String) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public typealias RunProbeChild = @Sendable (String, [String], ProbeChildOptions) async throws -> ProbeChildOutput

public struct OpenCodeModelsResult: Sendable, Equatable {
    public var status: Int?
    public var stdout: String
    public var errorMessage: String?

    public init(status: Int?, stdout: String, errorMessage: String?) {
        self.status = status
        self.stdout = stdout
        self.errorMessage = errorMessage
    }
}

public enum OpenCodeModelSource: Sendable, Equatable {
    case error(retryable: Bool)
    case noModels
    case live(models: [String])

    public var kind: String {
        switch self {
        case .error: "error"
        case .noModels: "no_models"
        case .live: "live"
        }
    }
}

public struct OpenCodeModelsDeps {
    public var platform: String
    public var windowsEnvironmentReaderFn: () -> [String: String]
    public var existsSyncFn: (String) -> Bool
    /// Synchronous child runner used by the sync twins: returns stdout or throws
    /// an error carrying `status`/`code` like the upstream child errors.
    public var execFileSyncFn: (String, [String]) throws -> String
    public var spawnSyncFn: ((String, [String], [String: String]) -> (status: Int?, stdout: String, errorCode: String?))?

    public init(
        platform: String,
        windowsEnvironmentReaderFn: @escaping () -> [String: String] = { [:] },
        existsSyncFn: @escaping (String) -> Bool = { _ in false },
        execFileSyncFn: @escaping (String, [String]) throws -> String
    ) {
        self.platform = platform
        self.windowsEnvironmentReaderFn = windowsEnvironmentReaderFn
        self.existsSyncFn = existsSyncFn
        self.execFileSyncFn = execFileSyncFn
    }
}

public enum OpenCodeModelsCommand {
    static let resolveFailure = "Cannot resolve OpenCode CLI entry point on Windows"
    static let modelsTimeoutMs = 5_000

    static func listingArgs(version: String) -> [String] {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        let major = Int(parts.first ?? "0") ?? 0
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let patch = parts.count > 2 ? Int(parts[2].prefix(while: \.isNumber)) ?? 0 : 0
        if major >= 2, minor > 0 || patch >= 27 { return ["models", "--standalone"] }
        return ["models"]
    }

    /// Sync listing. Resolution failure yields a nil status with the resolve
    /// message instead of throwing.
    public static func runSync(home: String, deps: OpenCodeModelsDeps) -> OpenCodeModelsResult {
        do {
            let executable = try resolveSync(deps: deps)
            let version = (try? deps.execFileSyncFn(executable, ["--version"])) ?? ""
            let args = listingArgs(version: version)
            let stdout = try deps.execFileSyncFn(executable, args)
            return .init(status: 0, stdout: stdout, errorMessage: nil)
        } catch let error as ProbeChildError {
            return .init(status: error.status, stdout: "", errorMessage: error.status == nil ? error.message : nil)
        } catch {
            return .init(status: nil, stdout: "", errorMessage: (error as NSError).domain == "opencode.resolve" ? error.localizedDescription : nil)
        }
    }

    static func resolveSync(deps: OpenCodeModelsDeps) throws -> String {
        if deps.platform != "win32" { return "opencode" }
        if let raw = try? deps.execFileSyncFn("powershell.exe", []), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fallback = "opencode"
        if deps.existsSyncFn(fallback) { return fallback }
        throw ProbeChildError(resolveFailure, code: "resolve")
    }

    /// Async listing through the injected probe child. Aborts propagate; all
    /// other failures map exactly like the synchronous path.
    public static func runAsync(
        home: String,
        deps: OpenCodeModelsDeps,
        runProbeChild: RunProbeChild,
        preAborted: Bool = false
    ) async throws -> OpenCodeModelsResult {
        if preAborted {
            throw ProbeChildError("aborted", code: "ABORT_ERR")
        }
        let executable: String
        do {
            executable = try await resolveAsync(deps: deps, runProbeChild: runProbeChild)
        } catch let error as ProbeChildError where error.code == "ABORT_ERR" {
            throw error
        } catch {
            return .init(status: nil, stdout: "", errorMessage: (error as? ProbeChildError)?.message ?? resolveFailure)
        }
        do {
            let versionOutput = try await runProbeChild(executable, ["--version"], options(home: home, timeoutMs: modelsTimeoutMs))
            let version = versionOutput.stdout
            let listing = try await runProbeChild(
                executable, listingArgs(version: version),
                options(home: home, timeoutMs: modelsTimeoutMs)
            )
            return .init(status: 0, stdout: listing.stdout, errorMessage: nil)
        } catch let error as ProbeChildError where error.code == "ABORT_ERR" {
            throw error
        } catch let error as ProbeChildError {
            if let status = error.status {
                return .init(status: status, stdout: "", errorMessage: nil)
            }
            return .init(status: nil, stdout: "", errorMessage: error.message)
        }
    }

    static func resolveAsync(deps: OpenCodeModelsDeps, runProbeChild: RunProbeChild) async throws -> String {
        if deps.platform != "win32" { return "opencode" }
        if let output = try? await runProbeChild("powershell.exe", ["-NoProfile", "-Command", "(Get-Command opencode).Source"], options(home: "", timeoutMs: 2_000)),
           !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if deps.existsSyncFn("opencode") { return "opencode" }
        throw ProbeChildError(resolveFailure, code: "resolve")
    }

    static func options(home: String, timeoutMs: Int) -> ProbeChildOptions {
        .init(timeoutMs: timeoutMs, shell: false, env: ["HOME": home, "NO_COLOR": "1"])
    }

    public static func detect(source: OpenCodeModelsResult) -> OpenCodeModelSource {
        guard let status = source.status else { return .error(retryable: true) }
        guard status == 0 else { return .error(retryable: true) }
        let models = source.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return models.isEmpty ? .noModels : .live(models: models)
    }

    public static func detectSync(home: String, deps: OpenCodeModelsDeps) -> OpenCodeModelSource {
        detect(source: runSync(home: home, deps: deps))
    }

    public static func detectAsync(
        home: String,
        deps: OpenCodeModelsDeps,
        runProbeChild: RunProbeChild,
        preAborted: Bool = false
    ) async throws -> OpenCodeModelSource {
        detect(source: try await runAsync(home: home, deps: deps, runProbeChild: runProbeChild, preAborted: preAborted))
    }
}
