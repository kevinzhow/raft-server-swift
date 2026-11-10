import Foundation
import RaftShared

/// Ephemeral transport inputs, never a durable execution reference or log value.
/// Only the worker's wire encoder consumes these JSON objects.
public enum AgentExecutionMaterializedPayload: Sendable {
    case start(configuration: Data)
    case delivery(message: Data, sequence: Int64)
    /// A transient system-sender notice: no messages row and no stored seq.
    /// The frame envelope always carries `seq: 0`.
    case notice(message: Data)
}

/// These failures contain no config, message content, URL or credential material.
public enum AgentExecutionMaterializationError: Error, Sendable, Equatable {
    case commandUnavailable
    case credentialUnavailable
    case configurationUnavailable
    case invalidServerURL
    case messageUnavailable
    case invalidSequence
}

struct MaterializedCodexConfiguration: Sendable {
    let name: String
    let displayName: String
    let description: String?
    let model: String
    let runtimeConfig: JSONValue
    let reasoningEffort: String?
    let envVars: [String: String]
    let sessionId: String?
    let serverURL: String
    let credentialKey: String
    let credentialId: String
    let agentId: String
    let serverId: String
    let machineId: String
    let machineName: String
    let machineDescription: String?
    let machineHostname: String?
    let daemonVersion: String?

    func encoded() throws -> Data {
        // Node AgentConfig + AgentRuntimeContext. The empty legacy bearer is
        // intentional: the runner uses the distinct scoped private credential.
        try JSONValue.object([
            "name": .string(name), "displayName": .string(displayName), "description": Self.nullable(description),
            "model": .string(model), "runtime": .string("codex"), "runtimeConfig": runtimeConfig,
            "reasoningEffort": Self.nullable(reasoningEffort),
            "envVars": envVars.isEmpty ? .null : .object(envVars.mapValues(JSONValue.string)),
            "sessionId": Self.nullable(sessionId), "serverUrl": .string(serverURL), "authToken": .string(""),
            "agentCredentialKey": .string(credentialKey), "agentCredentialId": .string(credentialId),
            "runtimeContext": .object([
                "agentId": .string(agentId), "serverId": .string(serverId), "machineId": .string(machineId),
                "machineName": .string(machineName), "machineDescription": Self.nullable(machineDescription),
                "machineHostname": Self.nullable(machineHostname), "machineOs": .null,
                "daemonVersion": Self.nullable(daemonVersion), "workspacePath": .null,
            ]),
        ]).data()
    }

    static func nullable(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}

struct MaterializedAgentDelivery: Sendable {
    let message: StoredHumanMessage
    let localChannelId: String
    let channelName: String
    let channelType: String
    let senderName: String
    let senderDescription: String?
    let recipientId: String
    let task: TaskRecord?
    let taskAssigneeName: String?
    let attachments: [ChannelAttachment]
    let parent: (id: String, name: String, type: String)?

    func encoded() throws -> Data {
        var body: [String: JSONValue] = [
            "channel_id": .string(localChannelId), "channel_name": .string(channelName), "channel_type": .string(channelType),
            "message_id": .string(message.id), "sender_id": .string(message.senderId), "sender_name": .string(senderName),
            "sender_type": .string(message.messageType == "system" || message.senderId == "system"
                ? "system" : message.senderType == "user" ? "human" : message.senderType),
            "content": .string(message.content), "timestamp": .string(DateText.isoString(message.createdAt)),
            "seq": .integer(Int64(message.seq)),
            "mentioned": .bool(message.mentions.contains { $0.type == "agent" && $0.id == recipientId }),
        ]
        if let senderDescription { body["sender_description"] = .string(senderDescription) }
        if let timezone = message.senderTimezone { body["sender_timezone"] = .string(timezone) }
        if let parent {
            body["parent_channel_id"] = .string(parent.id)
            body["parent_channel_name"] = .string(parent.name)
            body["parent_channel_type"] = .string(parent.type)
        }
        if !attachments.isEmpty {
            body["attachments"] = .array(attachments.map { attachment in
                var result: [String: JSONValue] = ["id": .string(attachment.id), "filename": .string(attachment.filename),
                    "mimeType": MaterializedCodexConfiguration.nullable(attachment.mimeType)]
                if let size = attachment.sizeBytes { result["sizeBytes"] = .integer(Int64(size)) }
                return .object(result)
            })
        }
        if let task {
            body["task_status"] = .string(task.status)
            body["task_number"] = .integer(Int64(task.taskNumber))
            body["task_assignee_id"] = MaterializedCodexConfiguration.nullable(task.assigneeId)
            body["task_assignee_type"] = MaterializedCodexConfiguration.nullable(task.assigneeType == "user" ? "human" : task.assigneeType)
            body["task_assignee_name"] = MaterializedCodexConfiguration.nullable(taskAssigneeName)
            body["task_current_projection"] = .object([
                "title": .string(task.title), "description": MaterializedCodexConfiguration.nullable(task.description),
                "revision": .integer(Int64(task.revision)), "superseded": .bool(task.superseded),
                "amended_at": MaterializedCodexConfiguration.nullable(task.amendedAt.map(DateText.isoString)),
                "amended_by_type": MaterializedCodexConfiguration.nullable(task.amendedByType),
                "amended_by_name": MaterializedCodexConfiguration.nullable(task.amendedByName),
                "source": .string("tasks_current_projection"),
            ])
        } else if message.taskStatus != nil || message.taskNumber != nil {
            // Historical message-owned task fields remain valid when no canonical
            // task row exists. Canonical mutable text always wins when present.
            body["task_status"] = MaterializedCodexConfiguration.nullable(message.taskStatus)
            body["task_number"] = message.taskNumber.map { .integer(Int64($0)) } ?? .null
            body["task_assignee_id"] = MaterializedCodexConfiguration.nullable(message.taskAssigneeId)
            body["task_assignee_type"] = MaterializedCodexConfiguration.nullable(message.taskAssigneeType == "user" ? "human" : message.taskAssigneeType)
            body["task_assignee_name"] = MaterializedCodexConfiguration.nullable(taskAssigneeName)
        }
        return try JSONValue.object(body).data()
    }
}

/// The body of an upstream transient agent notice. The frame envelope adds
/// `seq: 0` and `deliveryId`; the body carries the synthetic `message_id` the
/// pinned server sends for the opener ledger and the owner-facts context.
/// Sender identity is always the system principal, and no `seq` member is
/// invented in the body.
struct MaterializedAgentNotice: Sendable {
    let channelId: String
    let messageId: String
    let notice: AgentExecutionNotice

    func encoded() throws -> Data {
        try JSONValue.object([
            "channel_id": .string(channelId), "channel_name": .string(notice.channelName),
            "channel_type": .string(notice.channelType), "message_id": .string(messageId),
            "sender_id": .string("system"), "sender_name": .string("system"),
            "sender_type": .string("system"), "content": .string(notice.content),
            "timestamp": .string(notice.timestamp),
        ]).data()
    }
}
