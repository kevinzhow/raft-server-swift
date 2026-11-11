import Foundation

// MARK: - Internal agent surface: task history, unclaim and the disabled upload sessions

/// One `GET /internal/agent-api/tasks/history` task card.
///
/// Upstream `agentApiTaskCardProjectionSchema`: exactly `taskNumber`, `title`,
/// `description` and `revision`. It is not the full channel task projection.
public struct AgentTaskCardProjection: Sendable, Equatable {
    public var taskNumber: Int
    public var title: String
    public var description: String?
    public var revision: Int

    public init(taskNumber: Int, title: String, description: String?, revision: Int) {
        self.taskNumber = taskNumber
        self.title = title
        self.description = description
        self.revision = revision
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("taskNumber", taskNumber),
            OrderedJSONField("title", title),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("revision", revision),
        ])
    }
}

/// `GET /internal/agent-api/tasks/history`: `{task, events}`.
///
/// The events are the shared canonical `task_events` projection
/// (`TaskHistoryEventDTO`), so the agent and human history reads cannot drift.
public struct AgentTaskHistoryResponse: Sendable, Equatable, JSONBodyConvertible {
    public let task: AgentTaskCardProjection
    public let events: [TaskHistoryEventDTO]

    public init(task: AgentTaskCardProjection, events: [TaskHistoryEventDTO]) {
        self.task = task
        self.events = events
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("task", task.jsonBody),
            OrderedJSONField("events", .array(events.map(\.jsonBody))),
        ])
    }
}

/// `POST /internal/agent-api/tasks/unclaim` success body.
public struct AgentTaskUnclaimResponse: Sendable, Equatable, JSONBodyConvertible {
    public init() {}

    public var jsonBody: OrderedJSON { .object([OrderedJSONField("ok", true)]) }
}

/// Upstream `validateAgentApiRequestPart` refusal for a body/query that fails
/// the published agent-api contract. The validator runs before the handler, so
/// the status and `code` are the contract's, not the domain's.
public struct AgentApiContractInvalidResponse: Sendable, Equatable, JSONBodyConvertible {
    public struct Issue: Sendable, Equatable {
        public var path: String
        public var message: String

        public init(path: String, message: String) {
            self.path = path
            self.message = message
        }
    }

    public let part: String
    public let routeKey: String
    public let issues: [Issue]

    public init(routeKey: String, part: String, issues: [Issue]) {
        self.routeKey = routeKey
        self.part = part
        self.issues = issues
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("error", "Invalid agent-api \(routeKey) \(part)"),
            OrderedJSONField("code", "agent_api_contract_invalid"),
            OrderedJSONField("issues", .array(issues.map { issue in
                .object([
                    OrderedJSONField("path", issue.path),
                    OrderedJSONField("message", issue.message),
                ])
            })),
        ])
    }
}

/// The flat error body the credential routes publish when the direct-upload
/// service is not installed. Upstream keeps this body for every upload-session
/// verb in a deployment without the service (this port has no presigned object
/// upload, so `GET /internal/agent-api/attachment-upload-capabilities` already
/// declares `directUploadEnabled: false`).
public struct AttachmentUploadSessionDisabledResponse: Sendable, Equatable, JSONBodyConvertible {
    public init() {}

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("code", "UPLOAD_SESSION_NOT_FOUND"),
            OrderedJSONField("message", "Direct uploads are disabled."),
            OrderedJSONField("retryable", false),
        ])
    }
}

/// The flat invalid-request body of the upload-session contract.
public struct AttachmentUploadInvalidRequestResponse: Sendable, Equatable, JSONBodyConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("code", "UPLOAD_INVALID_REQUEST"),
            OrderedJSONField("message", message),
            OrderedJSONField("retryable", false),
        ])
    }
}

/// One `GET /internal/agent/:id/tasks` row: the canonical task projection plus
/// the `readOnlyReason` upstream `projectTasksToChannel` adds.
///
/// The port does not model historical joint task surfaces, so the reason is
/// always `null`; it is published (rather than omitted) because the legacy
/// daemon reads the key's presence.
public struct LegacyAgentTaskProjection: Sendable, Equatable, JSONBodyConvertible {
    public let base: TaskReadProjection

    public init(base: TaskReadProjection) {
        self.base = base
    }

    public var jsonBody: OrderedJSON {
        guard case .object(var fields) = base.jsonBody else { return base.jsonBody }
        fields.append(OrderedJSONField("readOnlyReason", .null))
        return .object(fields)
    }
}

/// `GET /internal/agent/:id/tasks` body.
public struct LegacyAgentTaskListResponse: Sendable, Equatable, JSONBodyConvertible {
    public let tasks: [LegacyAgentTaskProjection]

    public init(tasks: [LegacyAgentTaskProjection]) {
        self.tasks = tasks
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("tasks", .array(tasks.map(\.jsonBody)))])
    }
}

/// `GET /internal/agent/:id/receive` body when the legacy machine inbox has no
/// queued message. The port has no agent orchestrator queue, so a receive is an
/// empty delivery rather than a fabricated message list.
public struct AgentReceiveMessagesResponse: Sendable, Equatable, JSONBodyConvertible {
    public let messages: [OrderedJSON]

    public init(messages: [OrderedJSON] = []) {
        self.messages = messages
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("messages", .array(messages))])
    }
}

// MARK: - Integration app management (agent credential surface)

/// `POST /internal/agent-api/integrations/app/logo` body.
public struct AgentIntegrationAppLogoResponse: Sendable, Equatable, JSONBodyConvertible {
    public let clientId: String
    public let clientKey: String
    public let clientName: String
    public let logoUrl: String

    public init(clientId: String, clientKey: String, clientName: String, logoUrl: String) {
        self.clientId = clientId
        self.clientKey = clientKey
        self.clientName = clientName
        self.logoUrl = logoUrl
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("clientId", clientId),
            OrderedJSONField("clientKey", clientKey),
            OrderedJSONField("clientName", clientName),
            OrderedJSONField("logoUrl", logoUrl),
        ])
    }
}

/// `POST /internal/agent-api/integrations/app/rotate-secret` body.
public struct AgentIntegrationAppRotateSecretResponse: Sendable, Equatable, JSONBodyConvertible {
    public let clientId: String
    public let clientKey: String
    public let clientName: String
    public let clientSecret: String

    public init(clientId: String, clientKey: String, clientName: String, clientSecret: String) {
        self.clientId = clientId
        self.clientKey = clientKey
        self.clientName = clientName
        self.clientSecret = clientSecret
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("clientId", clientId),
            OrderedJSONField("clientKey", clientKey),
            OrderedJSONField("clientName", clientName),
            OrderedJSONField("clientSecret", clientSecret),
        ])
    }
}

/// `POST /internal/agent-api/integrations/app/transfer-owner` body.
public struct AgentIntegrationAppTransferOwnerResponse: Sendable, Equatable, JSONBodyConvertible {
    public let clientId: String
    public let clientKey: String
    public let clientName: String
    public let ownerAgentId: String
    public let ownerAgentName: String
    public let ownershipOutcome: String
    public let auditEventId: String

    public init(
        clientId: String,
        clientKey: String,
        clientName: String,
        ownerAgentId: String,
        ownerAgentName: String,
        ownershipOutcome: String,
        auditEventId: String
    ) {
        self.clientId = clientId
        self.clientKey = clientKey
        self.clientName = clientName
        self.ownerAgentId = ownerAgentId
        self.ownerAgentName = ownerAgentName
        self.ownershipOutcome = ownershipOutcome
        self.auditEventId = auditEventId
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("clientId", clientId),
            OrderedJSONField("clientKey", clientKey),
            OrderedJSONField("clientName", clientName),
            OrderedJSONField("ownerAgentId", ownerAgentId),
            OrderedJSONField("ownerAgentName", ownerAgentName),
            OrderedJSONField("ownershipOutcome", ownershipOutcome),
            OrderedJSONField("auditEventId", auditEventId),
        ])
    }
}

/// One private share link projection. The token is never part of the view.
public struct AgentIntegrationAppShareLinkView: Sendable, Equatable {
    public let id: String
    public let expiresAt: String?
    public let revokedAt: String?
    public let lastUsedAt: String?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        expiresAt: String?,
        revokedAt: String?,
        lastUsedAt: String?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("expiresAt", optional: expiresAt),
            OrderedJSONField("revokedAt", optional: revokedAt),
            OrderedJSONField("lastUsedAt", optional: lastUsedAt),
            OrderedJSONField("createdAt", createdAt),
            OrderedJSONField("updatedAt", updatedAt),
        ])
    }
}

/// `POST /internal/agent-api/integrations/app/manage` body.
///
/// The optional members are omitted unless the action produces them, exactly
/// like the upstream object built from `undefined` locals. `link` is present
/// for all three share-link actions (null when no active link exists).
public struct AgentIntegrationAppManageResponse: Sendable, Equatable, JSONBodyConvertible {
    public let action: String
    public let clientId: String
    public let clientKey: String
    public let clientName: String
    public let publishStatus: String?
    public let logoUrl: String?
    public let logoUrlPresent: Bool
    public let shareUrl: String?
    public let link: AgentIntegrationAppShareLinkView?
    public let linkPresent: Bool

    public init(
        action: String,
        clientId: String,
        clientKey: String,
        clientName: String,
        publishStatus: String? = nil,
        logoUrl: String? = nil,
        logoUrlPresent: Bool = false,
        shareUrl: String? = nil,
        link: AgentIntegrationAppShareLinkView? = nil,
        linkPresent: Bool = false
    ) {
        self.action = action
        self.clientId = clientId
        self.clientKey = clientKey
        self.clientName = clientName
        self.publishStatus = publishStatus
        self.logoUrl = logoUrl
        self.logoUrlPresent = logoUrlPresent
        self.shareUrl = shareUrl
        self.link = link
        self.linkPresent = linkPresent
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("action", action)
        body.append("clientId", clientId)
        body.append("clientKey", clientKey)
        body.append("clientName", clientName)
        body.append("publishStatus", optional: publishStatus)
        if logoUrlPresent { body.append("logoUrl", logoUrl.map(OrderedJSON.string) ?? .null) }
        body.append("shareUrl", optional: shareUrl)
        if linkPresent {
            body.append("link", link?.jsonBody ?? .null)
        }
        return body.json
    }
}
