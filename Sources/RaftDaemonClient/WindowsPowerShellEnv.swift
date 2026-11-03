import Foundation

/// Windows PowerShell child environment: PowerShell 7 exports a module path
/// that can break Windows PowerShell 5.1 startup, so every case variant of
/// `PSModulePath` is omitted and the child initializes its own edition's path.
/// The source environment is never mutated. Ported from the upstream daemon.
public enum WindowsPowerShellEnv {
    public static func childEnv(from env: [String: String]? = nil) -> [String: String] {
        let source = env ?? ProcessInfo.processInfo.environment
        var childEnv = source
        for key in childEnv.keys where key.lowercased() == "psmodulepath" {
            childEnv[key] = nil
        }
        return childEnv
    }
}
