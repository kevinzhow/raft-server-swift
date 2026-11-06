import RaftShared

/// Resource receipts retain the legacy object-only shape and sorted JSON bytes.
enum MarketplaceReceiptProjection {
    static func renderObjectReceipt(_ payload: JSONValue) -> String {
        guard case .object = payload else { return "{}" }
        return LegacySortedJSON.render(payload) ?? "{}"
    }
}
