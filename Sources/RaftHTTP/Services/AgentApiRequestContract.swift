import Foundation
import RaftShared

/// Route-level request validation for the internal agent API contract.
///
/// The pinned surface validates params/query/body before the handler with the
/// shared zod schemas and publishes one 400 shape
/// (`agent_api_contract_invalid` with `issues`). The feature layer owns the
/// paths and the service layer owns the domain; this type owns only the shape
/// checks and the published issue projection, so no route file needs to parse
/// JSON itself.
public enum AgentApiRequestContract {
    public struct Validated<Value: Sendable>: Sendable {
        public let value: Value?
        public let issues: [AgentApiContractInvalidResponse.Issue]

        public var isValid: Bool { value != nil && issues.isEmpty }

        static func valid(_ value: Value) -> Self { .init(value: value, issues: []) }
        static func invalid(_ issues: [AgentApiContractInvalidResponse.Issue]) -> Self {
            .init(value: nil, issues: issues)
        }
    }

    // MARK: - Task history / unclaim

    public struct TaskHistoryQuery: Sendable, Equatable {
        public let channel: String
        public let taskNumber: Int
    }

    public static func taskHistoryQuery(rawQuery: String?) -> Validated<TaskHistoryQuery> {
        let channel = (queryValue(rawQuery, "channel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawNumber = queryValue(rawQuery, "task_number")
        var issues: [AgentApiContractInvalidResponse.Issue] = []
        if channel.isEmpty {
            issues.append(.init(path: "channel", message: "Required"))
        }
        guard let taskNumber = rawNumber.flatMap(Int.init), taskNumber > 0 else {
            issues.append(.init(path: "task_number", message: "Expected a positive integer"))
            return .invalid(issues)
        }
        if !issues.isEmpty { return .invalid(issues) }
        return .valid(TaskHistoryQuery(channel: channel, taskNumber: taskNumber))
    }

    public struct TaskUnclaimBody: Sendable, Equatable {
        public let channel: String
        public let taskNumber: Int
    }

    public static func taskUnclaimBody(_ body: LegacyJSONObjectBody?) -> Validated<TaskUnclaimBody> {
        guard let body else {
            return .invalid([.init(path: "", message: "Expected an object")])
        }
        let channel = (body.string("channel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var issues: [AgentApiContractInvalidResponse.Issue] = []
        if channel.isEmpty {
            issues.append(.init(path: "channel", message: "Required"))
        }
        guard let taskNumber = body["task_number"].flatMap(integerValue), taskNumber > 0 else {
            issues.append(.init(path: "task_number", message: "Expected a positive integer"))
            return .invalid(issues)
        }
        if !issues.isEmpty { return .invalid(issues) }
        return .valid(TaskUnclaimBody(channel: channel, taskNumber: taskNumber))
    }

    // MARK: - Attachment upload sessions

    /// `createAttachmentUploadSessionRequestSchema`: the request fields are
    /// covered by the contract; the size cap is 200 MiB.
    public static func uploadSessionCreateBody(
        _ body: LegacyJSONObjectBody?
    ) -> Validated<Void> {
        guard let body else {
            return .invalid([.init(path: "", message: "Expected an object")])
        }
        let allowed: Set<String> = ["channelId", "filename", "mimeType", "sizeBytes", "clientRequestId"]
        var issues: [AgentApiContractInvalidResponse.Issue] = []
        for key in body.members.keys.sorted() where !allowed.contains(key) {
            issues.append(.init(path: key, message: "Unrecognized key"))
        }
        if !isUUIDString(body["channelId"]) {
            issues.append(.init(path: "channelId", message: "Invalid UUID"))
        }
        if !isText(body["filename"], max: 255) {
            issues.append(.init(path: "filename", message: "Expected a string of 1 to 255 characters"))
        }
        if !isText(body["mimeType"], max: 255) {
            issues.append(.init(path: "mimeType", message: "Expected a string of 1 to 255 characters"))
        }
        let size = body["sizeBytes"].flatMap(integerValue)
        if size == nil || (size ?? 0) <= 0 || (size ?? 0) > 200 * 1024 * 1024 {
            issues.append(.init(path: "sizeBytes", message: "Expected a positive integer at most 209715200"))
        }
        if !isUUIDString(body["clientRequestId"]) {
            issues.append(.init(path: "clientRequestId", message: "Invalid UUID"))
        }
        return issues.isEmpty ? .valid(()) : .invalid(issues)
    }

    // MARK: - Integration app management

    public struct IntegrationManageBody: Sendable, Equatable {
        public let clientKey: String
        public let action: String
        public let expiresInDays: Int?
    }

    public static let integrationManageActions: Set<String> = [
        "share_link_get", "share_link_create", "share_link_revoke",
        "request_publish", "request_unpublish", "clear_logo", "delete",
    ]

    public static func integrationManageBody(_ body: IntegrationRequestBody?) -> Validated<IntegrationManageBody> {
        guard let body else {
            return .invalid([.init(path: "", message: "Expected an object")])
        }
        let clientKey = (body.string("clientKey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let action = body.string("action") ?? ""
        var issues: [AgentApiContractInvalidResponse.Issue] = []
        if clientKey.isEmpty {
            issues.append(.init(path: "clientKey", message: "Required"))
        }
        if !integrationManageActions.contains(action) {
            issues.append(.init(path: "action", message: "Invalid option"))
        }
        var expiresInDays: Int?
        if body.has("expiresInDays") {
            guard case .integer(let raw)? = body.value("expiresInDays"),
                  let days = Int(exactly: raw), days > 0, days <= 365
            else {
                issues.append(.init(path: "expiresInDays", message: "Expected a positive integer at most 365"))
                return .invalid(issues)
            }
            expiresInDays = days
        }
        if !issues.isEmpty { return .invalid(issues) }
        return .valid(IntegrationManageBody(
            clientKey: clientKey, action: action, expiresInDays: expiresInDays
        ))
    }

    public static func integrationClientKeyBody(
        _ body: IntegrationRequestBody?
    ) -> Validated<String> {
        guard let body else {
            return .invalid([.init(path: "", message: "Expected an object")])
        }
        let clientKey = (body.string("clientKey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return clientKey.isEmpty
            ? .invalid([.init(path: "clientKey", message: "Required")])
            : .valid(clientKey)
    }

    public struct IntegrationTransferBody: Sendable, Equatable {
        public let clientKey: String
        public let targetAgent: String
    }

    public static func integrationTransferBody(
        _ body: IntegrationRequestBody?
    ) -> Validated<IntegrationTransferBody> {
        guard let body else {
            return .invalid([.init(path: "", message: "Expected an object")])
        }
        let clientKey = (body.string("clientKey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let targetAgent = (body.string("targetAgent") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var issues: [AgentApiContractInvalidResponse.Issue] = []
        if clientKey.isEmpty { issues.append(.init(path: "clientKey", message: "Required")) }
        if targetAgent.isEmpty { issues.append(.init(path: "targetAgent", message: "Required")) }
        guard issues.isEmpty else { return .invalid(issues) }
        return .valid(IntegrationTransferBody(clientKey: clientKey, targetAgent: targetAgent))
    }

    // MARK: - Value helpers

    private static func queryValue(_ rawQuery: String?, _ name: String) -> String? {
        guard let rawQuery, !rawQuery.isEmpty else { return nil }
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let key = decodeQueryComponent(parts[0])
            guard key == name else { continue }
            return parts.count > 1 ? decodeQueryComponent(parts[1]) : ""
        }
        return nil
    }

    private static func decodeQueryComponent(_ raw: String) -> String {
        let withSpaces = raw.replacingOccurrences(of: "+", with: " ")
        return withSpaces.removingPercentEncoding ?? withSpaces
    }

    private static func isText(_ value: JSONValue?, max: Int) -> Bool {
        guard case .string(let text) = value else { return false }
        let count = text.count
        return count >= 1 && count <= max
    }

    private static func isUUIDString(_ value: JSONValue?) -> Bool {
        guard case .string(let text) = value else { return false }
        return UUID(uuidString: text) != nil
    }

    private static func integerValue(_ value: JSONValue) -> Int? {
        switch value {
        case .integer(let number): return Int(exactly: number)
        case .number(let number):
            guard number.rounded() == number, number >= Double(Int.min), number <= Double(Int.max) else { return nil }
            return Int(number)
        default:
            return nil
        }
    }
}
