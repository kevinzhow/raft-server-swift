import Foundation

public enum TaskCatalogPolicy {
    static func encodeCursor(channelId: String, taskNumber: Int) -> String {
        let payload = OrderedJSON.object([
            OrderedJSONField("c", channelId), OrderedJSONField("n", taskNumber),
        ]).render()
        return AuthTokenCodec.base64url(Data(payload.utf8))
    }

    static func decodeCursor(_ raw: String) -> (channelId: String, taskNumber: Int)? {
        var base64 = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let channelId = object["c"] as? String,
              channelId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil,
              let taskNumber = object["n"] as? Int
        else { return nil }
        return (channelId, taskNumber)
    }

    static let validTaskStatuses: Set<String> = ["todo", "in_progress", "in_review", "done", "closed", "cancelled"]

    static let labDefinitions: [(key: String, name: String, description: String, state: String)] = [
        ("open_lab", "Open Lab", "Available", "open"),
        ("paused_lab", "Paused Lab", "Paused", "paused"),
        ("draft_lab", "Draft Lab", "Hidden", "draft"),
        ("retired_lab", "Retired Lab", "Historical", "retired"),
    ]
}
