import Foundation

/// Cookie-banner mode for `GET /api/public/servers/:slug`.
///
/// A missing or malformed country asks. The opt-in countries ask. Canada asks
/// unless the province is present and is not Quebec. Elsewhere the id is on
/// unless `Sec-GPC` is `1`.

public enum PublicVisitorRegion {
    private static let askFirst: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE",
        "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
        "GF", "GP", "MQ", "RE", "YT", "MF", "AX",
        "IS", "LI", "NO",
        "GB", "CH", "BR", "KR", "SA", "CN",
    ]

    public static func visitorIdMode(country: String?, region: String?, gpc: String?) -> String {
        guard let country, country.wholeMatch(of: /^[A-Z]{2}$/) != nil else { return "ask" }
        if askFirst.contains(country) { return "ask" }
        if country == "CA" {
            let placed = region?.wholeMatch(of: /^[A-Z0-9]{1,3}$/) != nil && region != "QC"
            if !placed { return "ask" }
        }
        return gpc?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? "default_off" : "default_on"
    }
}
