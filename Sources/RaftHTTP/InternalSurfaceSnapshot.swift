/// One claimed internal surface: the HTTP method, the route pattern and the
/// credential principal that may call it.
public struct InternalSurfaceEntry: Sendable, Equatable {
    public var method: String
    public var path: String
    public var principal: String

    public init(method: String, path: String, principal: String) {
        self.method = method
        self.path = path
        self.principal = principal
    }
}

/// The route-auth projection `POST /internal/computer/preflight` publishes.
/// It is derived from the live router, never from a hand-maintained list, so a
/// registered-but-undescribed surface cannot be masked by a stale copy.
public struct InternalSurfaceSnapshot: Sendable, Equatable {
    public var surfaceVersion: String
    public var claimedPrefixes: [String]
    public var registeredPrincipals: [String]
    public var computerSurface: [InternalSurfaceEntry]

    public init(
        surfaceVersion: String,
        claimedPrefixes: [String],
        registeredPrincipals: [String],
        computerSurface: [InternalSurfaceEntry]
    ) {
        self.surfaceVersion = surfaceVersion
        self.claimedPrefixes = claimedPrefixes
        self.registeredPrincipals = registeredPrincipals
        self.computerSurface = computerSurface
    }

    public func computerSurfaceJSON() -> String {
        computerSurface
            .map { entry in
                "{\"method\":\(Self.jsonString(entry.method)),\"path\":\(Self.jsonString(entry.path)),\"principal\":\(Self.jsonString(entry.principal))}"
            }
            .joined(separator: ",")
    }

    private static func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
