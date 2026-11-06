/// Anonymous history path guards run before the readable-channel lookup.
public enum PublicServerMessages {
    public static func channel(channelId: String) -> PublicHistoryError {
        ServerScope.isUUID(channelId) ? .notFound : .channelMissing
    }
    public static func thread(threadChannelId: String) -> PublicHistoryError {
        ServerScope.isUUID(threadChannelId) ? .notFound : .threadMissing
    }
}
