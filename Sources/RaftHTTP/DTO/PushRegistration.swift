/// A device registration row owned by the notification domain.
public struct PushRegistration: Sendable {
    public var installationId: String
    public var provider: String
    public var env: String
    public var topic: String
    public var deviceToken: String
    public var appVersion: String?
    public var userId: String?
    public var serverId: String?
    public var sessionFamilyId: String?
    public var revokeCapability: String
}
