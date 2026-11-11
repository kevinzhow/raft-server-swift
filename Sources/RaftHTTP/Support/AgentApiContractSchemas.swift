import Foundation

/// The request schemas of the `/internal/agent-api` contract routes the port
/// implements.
///
/// Each table entry is the pinned `agentApiContract` zod schema for one
/// params/query/body part, transcribed into `AgentApiContractSchema`. The
/// route registration in `InternalAgentApiFeature` calls the one shared
/// validator; no route spells its own issue list.
enum AgentApiContractSchemas {
    typealias S = AgentApiContractSchema
    typealias O = AgentApiContractObject
    typealias F = AgentApiContractField

    static func object(
        for key: AgentApiContractRouteKey,
        part: AgentApiContractPart
    ) -> O? {
        switch (key, part) {
        case (.userChannels, .params): return userChannelsParams
        case (.userChannels, .query): return userChannelsQuery
        case (.historyRead, .query): return historyReadQuery
        case (.mentionActionsPending, .query): return mentionActionsPendingQuery
        case (.mentionActionsExecute, .body): return mentionActionsExecuteBody
        case (.messageReactionAdd, .params), (.messageReactionRemove, .params):
            return messageReactionParams
        case (.messageReactionAdd, .body), (.messageReactionRemove, .body):
            return messageReactionBody
        case (.channelJoin, .params), (.channelLeave, .params),
             (.channelMute, .params), (.channelUnmute, .params):
            return channelMembershipParams
        case (.channelCreate, .body): return channelCreateBody
        case (.channelUpdate, .params): return channelMembershipParams
        case (.channelUpdate, .body): return channelUpdateBody
        case (.channelArchive, .body), (.channelUnarchive, .body):
            return channelLifecycleBody
        case (.channelMemberAdd, .params), (.channelMemberRemove, .params):
            return channelMembershipParams
        case (.channelMemberAdd, .body), (.channelMemberRemove, .body):
            return channelMemberBody
        case (.channelMute, .body): return channelMuteBody
        case (.events, .query): return eventsQuery
        case (.attachmentDownload, .params), (.attachmentDownloadUrl, .params),
             (.attachmentCommentsList, .params):
            return attachmentParams
        case (.attachmentCommentsList, .query): return attachmentCommentsQuery
        case (.messageSend, .body), (.messageSendV2, .body):
            return key == .messageSendV2 ? messageSendV2Body : messageSendBody
        case (.resolveChannel, .body): return resolveChannelBody
        case (.messageSearch, .query): return messageSearchQuery
        case (.messageResolve, .params): return messageReactionParams
        case (.channelMembers, .query): return channelMembersQuery
        case (.threadUnfollow, .body): return threadUnfollowBody
        case (.inboxList, .query): return inboxListQuery
        case (.assistantOwnerInbox, .query): return assistantOwnerInboxQuery
        case (.assistantOwnerMessages, .query): return assistantOwnerMessagesQuery
        case (.profileShow, .query): return profileShowQuery
        case (.profileUpdate, .body): return profileUpdateBody
        case (.integrationMarketplaceSearch, .query): return integrationMarketplaceQuery
        case (.integrationToken, .body): return integrationTokenBody
        case (.integrationLogin, .body): return integrationLoginBody
        case (.integrationAppUpdate, .body): return integrationAppUpdateBody
        case (.integrationAppStatus, .query): return integrationAppStatusQuery
        case (.taskList, .query): return taskListQuery
        case (.taskCreate, .body): return taskCreateBody
        case (.taskClaim, .body): return taskClaimBody
        case (.taskAssign, .body): return taskAssignBody
        case (.taskUpdateStatus, .body): return taskUpdateStatusBody
        case (.taskResourceReceipt, .body): return taskResourceReceiptBody
        case (.taskDelete, .body): return taskDeleteBody
        case (.taskConvert, .body): return taskConvertBody
        case (.taskAmend, .body): return taskAmendBody
        case (.reminderList, .query): return reminderListQuery
        case (.reminderCreate, .body): return reminderCreateBody
        case (.reminderCancel, .params), (.reminderSnooze, .params),
             (.reminderUpdate, .params), (.reminderLog, .params):
            return reminderParams
        case (.reminderSnooze, .body): return reminderSnoozeBody
        case (.reminderUpdate, .body): return reminderUpdateBody
        case (.appConfigGet, .params), (.appConfigPatch, .params):
            return appConfigParams
        case (.appConfigPatch, .body): return appConfigPatchBody
        case (.actionPrepare, .body): return actionPrepareBody
        case (.managedMcpCall, .body): return managedMcpCallBody
        case (.feedbackLocatorIngest, .body): return feedbackLocatorIngestBody
        case (.feedbackLocatorList, .query): return feedbackLocatorListQuery
        default: return nil
        }
    }

    /// The body schema for routes whose request body is not a plain object
    /// schema (today `integrationAppPrepare`'s discriminated union).
    static func bodySchema(for key: AgentApiContractRouteKey) -> S? {
        switch key {
        case .integrationAppPrepare: return integrationAppPrepareBodySchema
        default: return object(for: key, part: .body).map(S.object)
        }
    }

    // MARK: - Shared members

    private static let optionalTrimmed = S.text(trim: true)
    private static let optionalStringArray = S.list(S.text(trim: true, min: 1))
    private static let optionalBoolean = S.boolean
    private static let optionalFiniteNumber = S.decimal()
    private static let taskStatus = S.enumeration(["todo", "in_progress", "in_review", "done", "closed"])
    private static let freshnessContextMode = S.enumeration(["inline", "withheld"])
    private static let seenExactSeqs = S.list(S.integer(positive: true), min: nil, max: 2_500)

    // MARK: - Users / history / events

    private static let userChannelsParams = O([
        .field("name", .text(trim: true, min: 1), required: true),
    ])

    private static let userChannelsQuery = O([
        .field("offset", .nonNegativeIntegerString()),
        .field("limit", .text(
            trim: true,
            pattern: "^([1-9]|[1-9][0-9]|1[0-9][0-9]|200)$",
            patternMessage: "must be an integer from 1 to 200"
        )),
    ])

    private static let historyReadQuery = O([
        .field("channel", .text(trim: true, min: 1), required: true),
        .field("before", optionalTrimmed),
        .field("after", optionalTrimmed),
        .field("around", optionalTrimmed),
        .field("limit", optionalTrimmed),
        .field("consume", .enumeration(["true", "false"])),
        .field("unread", .enumeration(["true", "false"])),
    ])

    private static let eventsQuery = O([
        .field("since", optionalTrimmed),
        .field("limit", optionalTrimmed),
        .field("ack", .enumeration(["cursor", "immediate"])),
    ])

    // MARK: - Mentions

    private static let mentionActionsPendingQuery = O([
        .field("limit", optionalTrimmed),
    ])

    private static let mentionActionsExecuteBody = O([
        .field("action", .enumeration(["notify", "add"]), required: true),
        .field("resolutionIds", optionalStringArray),
        .field("ids", optionalStringArray),
    ])

    // MARK: - Messages / channels

    private static let messageReactionParams = O([
        .field("msgId", .text(trim: true, min: 1), required: true),
    ])

    private static let messageReactionBody = O([
        .field("emoji", .text(
            trim: true,
            min: 1,
            max: 16,
            refinement: .noWhitespace("A single reaction emoji is required")
        ), required: true),
    ])

    private static let channelMembershipParams = O([
        .field("channelId", .text(trim: true, min: 1), required: true),
    ])

    private static let channelCreateBody = O([
        .field("name", .text(trim: true, min: 1), required: true),
        .field("description", .text(max: 500)),
        .field("visibility", .enumeration(["public", "private"])),
    ])

    private static let channelUpdateBody = O([
        .field("name", .text(trim: true, min: 1)),
        .field("description", .text(max: 500)),
        .field("visibility", .enumeration(["public", "private"])),
    ])

    private static let channelLifecycleBody = O([
        .field("target", .text(trim: true, min: 1), required: true),
    ])

    private static let channelMemberBody = O([
        .field("userId", .text(trim: true, min: 1)),
        .field("agentId", .text(trim: true, min: 1)),
        .field("user", .text(trim: true, min: 1)),
        .field("human", .text(trim: true, min: 1)),
        .field("agent", .text(trim: true, min: 1)),
    ])

    private static let channelMuteBody = O([
        .field("attentionHintAccepted", .object(O([
            .field("schema", .literal("attention-dependency-hint.v1"), required: true),
            .field("trigger", .enumeration(["M2", "M3"]), required: true),
            .field("scope", .text(trim: true, min: 1), required: true),
            .field("suggested_command", optionalTrimmed),
            .field("copy_version", .text(trim: true, min: 1), required: true),
            .field("epoch_ms", .integer(nonnegative: true), required: true),
        ]))),
    ])

    private static let resolveChannelBody = O([
        .field("target", .text(trim: true, min: 1), required: true),
    ])

    private static let channelMembersQuery = O([
        .field("channel", .text(trim: true, min: 1), required: true),
    ])

    private static let messageSearchQuery = O([
        .field("q", optionalTrimmed),
        .field("channel", optionalTrimmed),
        .field("sender", optionalTrimmed),
        .field("senderId", optionalTrimmed),
        .field("sort", .enumeration(["relevance", "recent"])),
        .field("before", optionalTrimmed),
        .field("after", optionalTrimmed),
        .field("limit", optionalTrimmed),
        .field("offset", optionalTrimmed),
        .field("cursor", optionalTrimmed),
    ])

    private static let threadUnfollowBody = O([
        .field("thread", .text(trim: true, min: 1), required: true),
        .field("reason", .text(trim: true, min: 1, max: 200)),
    ])

    private static let inboxListQuery = O([
        .field("view", .enumeration(["unread", "mentions"])),
        .field("before_seq", .positiveIntegerString()),
        .field("limit", .positiveIntegerString()),
    ])

    // MARK: - Assistant / profile

    private static let assistantOwnerInboxQuery = O([
        .field("filter", .enumeration(["all", "unread", "mentions", "unread_mentions"])),
        .field("limit", .positiveIntegerString()),
        .field("offset", .nonNegativeIntegerString()),
    ])

    private static let assistantOwnerMessagesQuery = O([
        .field("channelId", .uuid(), required: true),
        .field("before", optionalTrimmed),
        .field("after", optionalTrimmed),
        .field("around", optionalTrimmed),
        .field("limit", .positiveIntegerString()),
    ])

    private static let profileShowQuery = O([
        .field("target", optionalTrimmed),
    ])

    private static let profileUpdateBody = O([
        .field("avatarUrl", optionalTrimmed),
        .field("displayName", optionalTrimmed),
        .field("description", optionalTrimmed),
    ])

    // MARK: - Attachments

    private static let attachmentParams = O([
        .field("attachmentId", .text(trim: true, min: 1), required: true),
    ])

    private static let attachmentCommentsQuery = O([
        .field("limit", optionalTrimmed),
    ])

    // MARK: - Message send

    private static let messageSendKnownFields: [F] = [
        .field("target", .text()),
        .field("content", .text()),
        .field("attachmentIds", optionalStringArray),
        .field("idempotencyKey", optionalTrimmed),
        .field("reconcileOnly", optionalBoolean),
        .field("continue", optionalBoolean),
        .field("sendDraft", optionalBoolean),
        .field("continueAnyway", optionalBoolean),
        .field("draftReholdCount", optionalFiniteNumber),
        .field("draftReplacedExisting", optionalBoolean),
        .field("seenUpToSeq", optionalFiniteNumber),
        .field("seenExactSeqs", seenExactSeqs),
        .field("seenCards", .object(O([
            .field("channel", .nullable(.text(min: 1))),
            .field("peer", .nullable(.text(min: 1))),
        ]))),
        .field("freshnessContextMode", freshnessContextMode),
    ]

    private static let messageSendBody = O(messageSendKnownFields)

    private static let messageSendV2Body = O(messageSendKnownFields + [
        .field("mentions", .list(.object(O([
            .field("type", .enumeration(["user", "agent"]), required: true),
            .field("id", .uuid(), required: true),
            .field("name", .text(trim: true, min: 1, max: 128), required: true),
        ])))),
    ])

    // MARK: - Integrations

    private static let integrationMarketplaceQuery = O([
        .field("query", .text(trim: true, max: 200)),
        .field("limit", optionalTrimmed),
    ])

    private static let integrationTokenBody = O([
        .field("service", .text(
            trim: true,
            pattern: "^[a-z][a-z0-9-]{2,63}$"
        ), required: true),
    ], strict: true)

    private static let integrationLoginBody = O([
        .field("service", .text(trim: true, min: 1), required: true),
        .field("scopes", optionalStringArray),
        .field("target", optionalTrimmed),
    ])

    private static let integrationAppCommonFields: [F] = [
        .field("target", .text(trim: true, min: 1), required: true),
        .field("name", optionalTrimmed),
        .field("description", optionalTrimmed),
        .field("category", .text(trim: true, min: 1)),
        .field("homepageUrl", optionalTrimmed),
        .field("returnUrl", optionalTrimmed),
        .field("agentManifestUrl", optionalTrimmed),
        .field("setupUrl", optionalTrimmed),
        .field("setupDescription", optionalTrimmed),
        .field("scopes", optionalStringArray),
        .field("unsafeDemoUrlOverride", optionalBoolean),
        .field("draftHint", optionalTrimmed),
    ]

    /// `agentApiIntegrationAppPrepareBodySchema` is the body schema itself
    /// (`z.discriminatedUnion("mode", …)`), not an object that carries it.
    static let integrationAppPrepareBodySchema: S = .discriminatedUnion(discriminator: "mode", members: [
        .object(O([
            .field("mode", .literal("register"), required: true),
        ] + integrationAppCommonFields + [
            .field("clientKey", optionalTrimmed),
        ])),
        .object(O([
            .field("mode", .literal("update"), required: true),
        ] + integrationAppCommonFields + [
            .field("clientKey", .text(trim: true, min: 1), required: true),
        ])),
    ])

    private static let integrationAppUpdateBody = O([
        .field("clientKey", .text(trim: true, min: 1), required: true),
        .field("name", optionalTrimmed),
        .field("description", optionalTrimmed),
        .field("whenToUse", optionalTrimmed),
        .field("category", .text(trim: true, min: 1)),
        .field("homepageUrl", optionalTrimmed),
        .field("returnUrl", optionalTrimmed),
        .field("agentManifestUrl", optionalTrimmed),
        .field("setupUrl", optionalTrimmed),
        .field("setupDescription", optionalTrimmed),
        .field("scopes", optionalStringArray),
        .field("unsafeDemoUrlOverride", optionalBoolean),
    ])

    private static let integrationAppStatusQuery = O([
        .field("card", optionalTrimmed),
        .field("client", optionalTrimmed),
    ])

    // MARK: - Tasks

    private static let taskListQuery = O([
        .field("channel", .text(trim: true, min: 1)),
        .field("mine", .literal("true")),
        .field("status", .union([taskStatus, .literal("all")])),
    ], refinements: [
        .exactlyOneOf(["channel", "mine"], "exactly one of channel or mine=true is required"),
    ])

    private static let taskCreateBody = O([
        .field("channel", .text(trim: true, min: 1), required: true),
        .field("tasks", .list(.object(O([
            .field("title", .text(trim: true, min: 1), required: true),
            .field("creates_resource", .boolean),
        ])), min: 1), required: true),
        .field("assignee", .text(
            trim: true,
            refinement: .atHandle("assignee must be an @handle")
        )),
        .field("idempotencyKey", optionalTrimmed),
    ])

    private static let taskClaimBody = O([
        .field("channel", .text(trim: true, min: 1), required: true),
        .field("task_numbers", .list(.integer(positive: true))),
        .field("message_ids", optionalStringArray),
        .field("seenUpToSeq", optionalFiniteNumber),
        .field("seenExactSeqs", seenExactSeqs),
        .field("freshnessContextMode", freshnessContextMode),
    ])

    private static let taskAssignBody = O([
        .field("channel", .text(trim: true, min: 1), required: true),
        .field("task_number", .integer(positive: true), required: true),
        .field("assignee", .nullable(.text(trim: true, min: 1)), required: true),
        .field("expected_revision", .integer(nonnegative: true)),
    ])

    private static let taskUpdateStatusBody = O([
        .field("channel", .text(trim: true, min: 1), required: true),
        .field("task_number", .integer(positive: true), required: true),
        .field("status", taskStatus, required: true),
        .field("seenUpToSeq", optionalFiniteNumber),
        .field("seenExactSeqs", seenExactSeqs),
        .field("freshnessContextMode", freshnessContextMode),
    ])

    private static let taskResourceReceiptSchema = O([
        .field("object", .text(trim: true, min: 1), required: true),
        .field("purpose", .text(trim: true, min: 1), required: true),
        .field("teardown_owner", .text(
            trim: true,
            refinement: .atHandle("teardown_owner must be an @agent handle")
        ), required: true),
        .field("security_privacy", .text(trim: true, min: 1), required: true),
        .field("expiry", .datetime(), required: true),
        .field("runbook", .text(trim: true, min: 1), required: true),
        .field("tracking", .text(trim: true, min: 1), required: true),
    ])

    private static let taskResourceReceiptBody = O([
        .field("channel", .text(trim: true, min: 1), required: true),
        .field("task_number", .integer(positive: true), required: true),
        .field("receipt", .object(taskResourceReceiptSchema), required: true),
    ])

    private static let taskDeleteBody = O([
        .field("channel", .text(trim: true, min: 1), required: true),
        .field("task_number", .integer(positive: true), required: true),
    ])

    private static let taskConvertBody = O([
        .field("channel", .text(trim: true, min: 1), required: true),
        .field("message_id", .text(trim: true, min: 1), required: true),
    ])

    private static let taskAmendBody = O([
        .field("channel", .text(trim: true, min: 1), required: true),
        .field("task_number", .integer(positive: true), required: true),
        .field("title", .text(trim: true, min: 1, max: 10_000)),
        .field("description", .nullable(.text(max: 50_000))),
        .field("seenUpToSeq", optionalFiniteNumber),
        .field("seenExactSeqs", seenExactSeqs),
        .field("freshnessContextMode", freshnessContextMode),
    ], refinements: [
        .atLeastOneOf(["title", "description"], "At least one of title or description is required"),
    ])

    // MARK: - Reminders

    private static let reminderListQuery = O([
        .field("status", optionalTrimmed),
        .field("all", optionalTrimmed),
    ])

    private static let reminderParams = O([
        .field("reminderId", .text(trim: true, min: 1), required: true),
    ])

    private static let reminderCreateBody = O([
        .field("title", .text(), required: true),
        .field("fireAt", optionalTrimmed),
        .field("delaySeconds", optionalFiniteNumber),
        .field("msgId", .nullable(.text())),
        .field("payload", .any),
        .field("repeat", optionalTrimmed),
        .field("tz", optionalTrimmed),
        .field("channel", optionalTrimmed),
    ])

    private static let reminderSnoozeBody = O([
        .field("delaySeconds", .decimal(), required: true),
    ])

    private static let reminderUpdateBody = O([
        .field("fireAt", optionalTrimmed),
        .field("delaySeconds", optionalFiniteNumber),
        .field("repeat", optionalTrimmed),
        .field("title", optionalTrimmed),
        .field("tz", optionalTrimmed),
    ])

    // MARK: - App config

    private static let appConfigParams = O([
        .field("appId", .text(trim: true, min: 1), required: true),
    ])

    private static let appConfigPatchBody = O([
        .field("expectedRevision", .integer(nonnegative: true), required: true),
        .field("set", .record(.any)),
        .field("unset", .list(.text(trim: true, min: 1))),
    ], strict: true)

    // MARK: - Action card prepare

    private static let draftHint = S.text(trim: true, max: 2_000)
    private static let idOrHandle = S.text(min: 1, max: 120)
    private static let idOrHandleArray = S.list(idOrHandle, min: nil, max: 64)
    private static let scopedStringArray = S.list(S.text(trim: true, min: 1, max: 120), min: nil, max: 64)

    private static let integrationAppDraftFields: [F] = [
        .field("name", .text(trim: true, min: 1, max: 120)),
        .field("description", .text(trim: true, max: 1_000)),
        .field("category", .text(trim: true, min: 1, max: 120)),
        .field("homepageUrl", .text(trim: true, max: 2_000)),
        .field("returnUrl", .text(trim: true, max: 2_000)),
        .field("agentManifestUrl", .text(trim: true, max: 2_000)),
        .field("setupUrl", .text(trim: true, max: 2_000)),
        .field("setupDescription", .text(trim: true, max: 500)),
    ]

    private static let actionCardMembers: [S] = [
        .object(O([
            .field("type", .literal("channel:create"), required: true),
            .field("name", .text(trim: true, min: 1, max: 80), required: true),
            .field("visibility", .enumeration(["public", "private"])),
            .field("description", .text(trim: true, max: 500)),
            .field("initialHumans", idOrHandleArray),
            .field("initialAgents", idOrHandleArray),
            .field("draftHint", draftHint),
        ])),
        .object(O([
            .field("type", .literal("agent:create"), required: true),
            .field("name", .text(trim: true, min: 1, max: 60), required: true),
            .field("description", .text(trim: true, max: 500)),
            .field("suggestedComputer", idOrHandle),
            .field("requiredComputer", idOrHandle),
            .field("hosting", .enumeration(["computer", "antiproton"])),
            .field("model", .text(trim: true, min: 1, max: 200)),
            .field("draftHint", draftHint),
        ])),
        .object(O([
            .field("type", .literal("channel:add_member"), required: true),
            .field("channel", idOrHandle, required: true),
            .field("humans", idOrHandleArray),
            .field("agents", idOrHandleArray),
            .field("draftHint", draftHint),
        ])),
        .object(O([
            .field("type", .literal("integration:approve_agent_login"), required: true),
            .field("requestId", .uuid(), required: true),
            .field("agentId", .uuid(), required: true),
            .field("agentName", .text(trim: true, min: 1, max: 120), required: true),
            .field("clientId", .uuid(), required: true),
            .field("clientKey", .text(trim: true, min: 1, max: 120), required: true),
            .field("clientName", .text(trim: true, min: 1, max: 120), required: true),
            .field("scopes", scopedStringArray, required: true),
            .field("draftHint", draftHint),
        ])),
        .object(O([
            .field("type", .literal("integration:install_marketplace_app"), required: true),
            .field("clientId", .uuid(), required: true),
            .field("clientKey", .text(trim: true, min: 1, max: 120), required: true),
            .field("setupUrl", .text(max: 2_000)),
            .field("setupDescription", .text(max: 1_000)),
            .field("setupRevision", .integer(positive: true)),
            .field("clientName", .text(trim: true, min: 1, max: 1_000), required: true),
            .field("clientNameSha256", .text(pattern: "^[a-f0-9]{64}$"), required: true),
            .field("agentId", .uuid(), required: true),
            .field("agentName", .text(trim: true, min: 1, max: 120), required: true),
            .field("scopes", scopedStringArray, required: true),
            .field("draftHint", draftHint),
        ])),
        .object(O(integrationAppDraftFields + [
            .field("type", .literal("integration:register_app"), required: true),
            .field("clientKey", .text(trim: true, min: 1, max: 120)),
            .field("returnUrl", .text(trim: true, min: 1, max: 2_000), required: true),
            .field("scopes", scopedStringArray),
            .field("unsafeDemoUrlOverride", .boolean),
            .field("draftHint", draftHint),
        ])),
        .object(O(integrationAppDraftFields + [
            .field("type", .literal("integration:update_app_registration"), required: true),
            .field("clientKey", .text(trim: true, min: 1, max: 120), required: true),
            .field("scopes", scopedStringArray),
            .field("unsafeDemoUrlOverride", .boolean),
            .field("draftHint", draftHint),
        ])),
        .object(O([
            .field("type", .literal("integration:recover_app_owner"), required: true),
            .field("clientKey", .text(trim: true, min: 1, max: 120), required: true),
            .field("targetAgent", .text(trim: true, min: 1, max: 120), required: true),
            .field("draftHint", draftHint),
        ])),
    ]

    private static let actionPrepareBody = O([
        .field("target", .text(trim: true, min: 1), required: true),
        .field("action", .discriminatedUnion(
            discriminator: "type",
            members: actionCardMembers
        ), required: true),
        .field("idempotencyKey", optionalTrimmed),
    ])

    // MARK: - Managed MCP

    private static let managedMcpCallBody = O([
        .field("mcpServerId", .uuid(), required: true),
        .field("toolName", .text(trim: true, min: 1), required: true),
        .field("arguments", .record(.any), required: true),
        .field("expectedConfigVersion", .integer(positive: true), required: true),
        .field("expectedAssignmentVersion", .integer(positive: true), required: true),
    ])

    // MARK: - Feedback locators

    private static let feedbackLocatorIngestBody = O([
        .field("artifact_kind", .text(trim: true, min: 1, max: 128), required: true),
        .field("event_kind", .text(trim: true, min: 1, max: 128), required: true),
        .field("payload", .any, required: true),
    ], strict: true)

    private static let feedbackLocatorListQuery = O([
        .field("report_id", .uuid()),
        .field("runtime", .enumeration([
            "claude", "codex", "grok", "kimi", "kimi-sdk", "pi", "builtin", "other",
        ])),
        .field("native_status", .enumeration([
            "reachable", "unreachable", "unsupported", "not_attempted", "lookup_failed",
        ])),
        .field("native_lookup_method", .enumeration([
            "claude_jsonl", "codex_jsonl", "grok_session_jsonl", "kimi_sdk_index",
            "pi_jsonl", "builtin_jsonl", "none", "not_attempted",
        ])),
        .field("served_exact_sha256", .text(pattern: "^[0-9a-f]{64}$")),
        .field("route_basis", .enumeration([
            "explicit_public_channel", "configured_project_channel",
        ])),
        .field("limit", .text(trim: true, pattern: "^([1-9]|[1-9][0-9]|100)$")),
    ], strict: true)
}
