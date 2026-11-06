import Foundation

public struct DirectoryRuntimePolicy: Sendable {
    let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) { self.directory = directory }

    public var experimentalSurfacesDisabled: Bool {
        directory.lock.lock()
        let override = directory.experimentalSurfacesDisabledOverride
        directory.lock.unlock()
        if let override { return override }
        return (ProcessInfo.processInfo.environment["SLOCK_EXPERIMENTAL_SURFACES_DISABLED"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
    }
}
