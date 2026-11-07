public struct ServiceContainer: Sendable {
    public let identity: IdentityServices
    public let messaging: MessagingServices
    public let channels: ChannelServices
    public let agents: AgentServices
    public let machines: MachineServices
    public let tasks: TaskServices
    public let integrations: IntegrationServices
    public let notifications: NotificationServices
    public let feedback: FeedbackServices
}

extension ServiceContainer {
    public init() {
        self = composeServices()
    }
}
