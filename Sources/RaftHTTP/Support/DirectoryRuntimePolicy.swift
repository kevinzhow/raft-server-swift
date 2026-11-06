import Foundation

public struct DirectoryRuntimePolicy: Sendable {
    let profiles: AuthProfileStore

    public init(directory: EmailLoginDirectory) { profiles = directory.authProfileStore }

    public var experimentalSurfacesDisabled: Bool {
        let override = profiles.experimentalSurfacesDisabledOverride
        if let override { return override }
        return (ProcessInfo.processInfo.environment["SLOCK_EXPERIMENTAL_SURFACES_DISABLED"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
    }
}
