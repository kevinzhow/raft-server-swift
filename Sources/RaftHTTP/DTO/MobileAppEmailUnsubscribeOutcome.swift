/// The unsubscribe flow's four outcomes. Routes select status and headers.
public enum MobileAppEmailUnsubscribeOutcome: Sendable {
    case invalidLink(html: String)
    case confirmation(html: String)
    case unsubscribed(html: String)
    case oneClick
}
