import Foundation

public enum AuthLegalPolicy {
    public static let termsVersion = "2026-05-12"

    public static let privacyVersion = "2026-05-12"

    public static let termsURL = "https://raft.build/terms"

    public static let privacyURL = "https://raft.build/privacy"

    static var legalBody: OrderedJSON {
        .object([
            OrderedJSONField("termsVersion", termsVersion),
            OrderedJSONField("privacyVersion", privacyVersion),
            OrderedJSONField("termsUrl", termsURL),
            OrderedJSONField("privacyUrl", privacyURL),
        ])
    }

    static var legalObject: String { legalBody.render() }
}
