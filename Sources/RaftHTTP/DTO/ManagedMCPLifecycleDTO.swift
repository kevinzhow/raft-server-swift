import Foundation

// Request and response shapes for the read mutations, joint-invite accept,
// channel list, profile completion, server create/details/analytics, provider
// connection and push registration routes.
//
// Every response owns its published member order as an `OrderedJSON` tree
// (`JSONBodyConvertible`); the strings the retired handlers concatenated by
// hand are reproduced byte for byte. Request bodies decode through
// `LenientJSONObjectRequest` (a member of the wrong JSON type reads as the
// legacy `as?` nil) except the two bodies with a nested value.

// MARK: - Read mutations

/// `POST /api/channels/:id/conversation-read-all`.
public struct ConversationReadAllResponse: JSONBodyConvertible, Equatable {
    let serverId: String
    let scopes: [ReadAllScopeResult]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("scopes", .array(scopes.map { scope in
                .object([
                    OrderedJSONField("scopeId", scope.scopeId),
                    OrderedJSONField("maxReadSeq", scope.maxReadSeq),
                    OrderedJSONField("readStateVersion", scope.readStateVersion),
                ])
            })),
        ])
    }
}

/// `POST /api/messages/read-mutations`: one admission or one replay.
public enum ReadMutationResponse: JSONBodyConvertible, Equatable {
    case admitted(serverId: String, principalId: String, authoritySeq: Int, mutationId: String)
    case alreadyTerminal(scopeId: String, cursor: Int)
    case alreadyAdmitted

    /// `201` for a fresh admission, `200` for a replay.
    public var status: UInt {
        if case .admitted = self { return 201 }
        return 200
    }

    public var jsonBody: OrderedJSON {
        switch self {
        case .admitted(let serverId, let principalId, let authoritySeq, let mutationId):
            return .object([
                OrderedJSONField("outcome", "ADMITTED"),
                OrderedJSONField("serverId", serverId),
                OrderedJSONField("principalId", principalId),
                OrderedJSONField("authoritySeq", authoritySeq),
                OrderedJSONField("mutationId", mutationId),
            ])
        case .alreadyTerminal(let scopeId, let cursor):
            return .object([
                OrderedJSONField("outcome", "ALREADY_TERMINAL"),
                OrderedJSONField("ack", .object([
                    OrderedJSONField("terminalReason", "completed"),
                    OrderedJSONField("capturedBoundary", .array([.object([
                        OrderedJSONField("scopeId", scopeId),
                        OrderedJSONField("throughSeq", cursor),
                    ])])),
                    OrderedJSONField("scopes", .array([.object([
                        OrderedJSONField("scopeId", scopeId),
                        OrderedJSONField("maxReadSeq", cursor),
                    ])])),
                ])),
            ])
        case .alreadyAdmitted:
            return .object([OrderedJSONField("outcome", "ALREADY_ADMITTED")])
        }
    }
}

/// `GET /api/messages/read-mutations/frontier`.
public struct ReadMutationFrontierResponse: JSONBodyConvertible {
    let snapshot: ReadMutationFrontierSnapshot

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("nextAuthoritySeq", snapshot.snapshotUpperAuthoritySeq + 1)
        body.append("lastTerminalAuthoritySeq", snapshot.lastTerminalAuthoritySeq)
        body.append("snapshotUpperAuthoritySeq", snapshot.snapshotUpperAuthoritySeq)
        body.append("items", .array(snapshot.items.map { item in
            .object([
                OrderedJSONField("mutationId", item.mutationId),
                OrderedJSONField("authoritySeq", item.authoritySeq),
                OrderedJSONField("state", item.state),
            ])
        }))
        body.append("scopes", ifPresent: snapshot.scopeCursors.map { cursors in
            OrderedJSON.array(cursors.map { cursor in
                .object([
                    OrderedJSONField("scopeId", cursor.scopeId),
                    OrderedJSONField("maxReadSeq", cursor.maxReadSeq),
                ])
            })
        })
        return body.json
    }
}

// MARK: - Joint invite and channel list

/// `POST /api/channels/joint-invites/:id/accept`.
public struct JointInviteAcceptedResponse: JSONBodyConvertible, Equatable {
    let channelId: String
    let name: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", channelId),
            OrderedJSONField("name", name),
            OrderedJSONField("type", "joint"),
            OrderedJSONField("joined", true),
        ])
    }
}

/// `GET /api/channels`.
public struct ManagedMCPChannelListResponse: JSONBodyConvertible {
    struct Row: Sendable {
        let id: String
        let name: String
        let type: String
        let joined: Bool
        let archivedAt: Date?
        let lastMessageAt: Date?
        let activityMuted: Bool
        let muteFromSeq: Int?
        let prefsVersion: Int
        let collapseLongMessages: Bool
        let displayPrefsVersion: Int
        let channelRole: String
        let channelAdminBasis: String?
        let capability: Bool
        let isJoint: Bool
        let serverAdmin: Bool
    }

    let rows: [Row]

    public var jsonBody: OrderedJSON {
        .array(rows.map { row in
            let caps = OrderedJSON.object([
                OrderedJSONField("editChannelMetadata", row.capability),
                OrderedJSONField("archiveChannels", row.capability && !row.isJoint),
                OrderedJSONField("addChannelMembers", row.capability && !row.isJoint),
                OrderedJSONField("removeChannelMembers", row.capability && !row.isJoint),
                OrderedJSONField("changeChannelMemberRoles", row.capability),
                OrderedJSONField("manageGuestAccess", row.serverAdmin && !row.isJoint),
                OrderedJSONField("deleteChannels", row.serverAdmin),
                OrderedJSONField("changeChannelVisibility", row.serverAdmin),
                OrderedJSONField("federateChannels", row.serverAdmin),
            ])
            return .object([
                OrderedJSONField("id", row.id),
                OrderedJSONField("name", row.name),
                OrderedJSONField("type", row.type),
                OrderedJSONField("joined", row.name == "all" || row.joined),
                OrderedJSONField("archivedAt", optional: row.archivedAt.map(RuntimeUsageISO.string)),
                OrderedJSONField("lastMessageAt", optional: row.lastMessageAt.map(RuntimeUsageISO.string)),
                OrderedJSONField("activityMuted", row.activityMuted),
                OrderedJSONField("muteFromSeq", optional: row.muteFromSeq),
                OrderedJSONField("prefsVersion", row.prefsVersion),
                OrderedJSONField("activityMuteSupported", row.type == "channel"),
                OrderedJSONField("collapseLongMessages", row.collapseLongMessages),
                OrderedJSONField("displayPrefsVersion", row.displayPrefsVersion),
                OrderedJSONField("channelRole", row.channelRole),
                OrderedJSONField("channelAdminBasis", optional: row.channelAdminBasis),
                OrderedJSONField("channelCapabilities", caps),
            ])
        })
    }
}

// MARK: - Profile, server

/// `POST /api/auth/me/complete-profile`.
public struct ProfileCompletionResponse: JSONBodyConvertible {
    let name: String
    let displayName: String
    let completedAt: Date
    let user: AuthUserDTO

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("name", name),
            OrderedJSONField("displayName", displayName),
            OrderedJSONField("profileSetupCompletedAt", EmailLoginDirectory.isoString(completedAt)),
            OrderedJSONField("user", user.jsonBody),
        ])
    }
}

/// `POST /api/servers`: the created or already-owned server.
public struct ServerCreatedResponse: JSONBodyConvertible, Equatable {
    let id: String
    let name: String
    let slug: String
    let role: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("slug", slug),
            OrderedJSONField("role", role),
        ])
    }
}

/// `GET|PATCH /api/servers/:id/product-analytics-settings`.
public struct ProductAnalyticsSettingsResponse: JSONBodyConvertible, Equatable {
    let enabled: Bool
    let canManage: Bool

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("productAnalyticsEnabled", enabled),
            OrderedJSONField("canManageProductAnalytics", canManage),
        ])
    }
}

/// `GET /api/servers/:id`: the guest projection or the member projection.
public enum ServerDetailsResponse: JSONBodyConvertible {
    case guest(id: String, name: String, slug: String)
    case member(OAuthLedger.ServerProfile)

    public var jsonBody: OrderedJSON {
        switch self {
        case .guest(let id, let name, let slug):
            return .object([
                OrderedJSONField("id", id),
                OrderedJSONField("name", name),
                OrderedJSONField("slug", slug),
                OrderedJSONField("avatarUrl", .null),
            ])
        case .member(let profile):
            return .object([
                OrderedJSONField("id", profile.id),
                OrderedJSONField("ownerId", profile.ownerId),
                OrderedJSONField("name", profile.name),
                OrderedJSONField("slug", profile.slug),
                OrderedJSONField("avatarUrl", optional: profile.avatarUrl),
                OrderedJSONField("plan", profile.plan),
                OrderedJSONField("translationEnabled", profile.translationEnabled),
                OrderedJSONField("publiclyVisible", profile.publiclyVisible),
                OrderedJSONField("publicGuestJoinEnabled", profile.publicGuestJoinEnabled),
            ])
        }
    }
}

// MARK: - Provider connections

/// One provider connection as the routes publish it. The timestamps print with
/// the default ISO-8601 formatter (no fractional seconds), as before.
public struct ProviderConnectionBody: JSONBodyConvertible {
    let connection: ProviderConnection

    public var jsonBody: OrderedJSON {
        let formatter = ISO8601DateFormatter()
        return .object([
            OrderedJSONField("id", connection.id),
            OrderedJSONField("name", connection.name),
            OrderedJSONField("providerId", connection.providerId),
            OrderedJSONField("authMethod", "api_key"),
            OrderedJSONField("endpointUrl", optional: connection.endpointUrl),
            OrderedJSONField("supportsImageInput", connection.supportsImageInput),
            OrderedJSONField("enabled", true),
            OrderedJSONField("status", connection.status),
            OrderedJSONField("configVersion", connection.configVersion),
            OrderedJSONField("credentialVersion", connection.credentialVersion),
            OrderedJSONField("hasCredential", connection.hasCredential),
            OrderedJSONField("assignedAgentCount", 0),
            OrderedJSONField("latestVerified", .null),
            OrderedJSONField("lastCheckedAt", .null),
            OrderedJSONField("lastErrorCategory", .null),
            OrderedJSONField("createdAt", formatter.string(from: connection.createdAt)),
            OrderedJSONField("updatedAt", formatter.string(from: connection.updatedAt)),
        ])
    }
}

/// `GET /api/provider-connections`.
public struct ProviderConnectionListResponse: JSONBodyConvertible {
    struct Option: Sendable, Equatable {
        let id: String
        let label: String
    }

    let connections: [ProviderConnection]
    let options: [Option]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("connections", .array(connections.map { ProviderConnectionBody(connection: $0).jsonBody })),
            OrderedJSONField("providerOptions", .array(options.map { option in
                .object([
                    OrderedJSONField("id", option.id),
                    OrderedJSONField("label", option.label),
                    OrderedJSONField("providerKind", option.id.hasSuffix("-compatible") ? "gateway" : "preset"),
                ])
            })),
        ])
    }
}

/// `GET /api/provider-connections/:id/agents`.
public struct ProviderAssignedAgentsResponse: JSONBodyConvertible {
    struct Row: Sendable {
        let id: String
        let info: OAuthLedger.ProviderAgentInfo
        let computerName: String?
    }

    let agents: [Row]

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("agents", .array(agents.map { row in
            .object([
                OrderedJSONField("id", row.id),
                OrderedJSONField("name", row.info.name),
                OrderedJSONField("displayName", row.info.displayName),
                OrderedJSONField("runtime", row.info.runtime),
                OrderedJSONField("status", row.info.status),
                OrderedJSONField("computerName", optional: row.computerName),
                OrderedJSONField("deleted", row.info.deleted),
            ])
        }))])
    }
}

// MARK: - Push

/// `POST /api/push/registrations`.
public struct PushRegistrationResponse: JSONBodyConvertible, Equatable {
    let revokeCapability: String
    let installationId: String
    let provider: String
    let env: String
    let topic: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("revoke_capability", revokeCapability),
            OrderedJSONField("registration", .object([
                OrderedJSONField("installationId", installationId),
                OrderedJSONField("provider", provider),
                OrderedJSONField("env", env),
                OrderedJSONField("topic", topic),
            ])),
        ])
    }
}

/// `GET /api/push/delivery-status`.
public struct PushDeliveryStatusResponse: JSONBodyConvertible, Equatable {
    let serverIds: [String]
    let fcmActive: Bool

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("servers", .object(serverIds.map { serverId in
            OrderedJSONField(serverId, .object([OrderedJSONField("fcmActive", fcmActive)]))
        }))])
    }
}

/// `DELETE /api/push/registrations/:installationId`.
public struct PushUnbindResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var unbound: Int

    init(unbound: Int) {
        ok = true
        self.unbound = unbound
    }
}

/// `POST /api/push/subscribe` request.
///
/// The retired parser required a string `endpoint` and an object `keys` whose
/// `p256dh` and `auth` are strings; any other shape is the published 400, so a
/// wrong member reads as absent here.
public struct WebPushSubscribeRequest: Decodable, Sendable, Equatable {
    public var endpoint: String?
    public var p256dh: String?
    public var auth: String?

    public init(endpoint: String? = nil, p256dh: String? = nil, auth: String? = nil) {
        self.endpoint = endpoint
        self.p256dh = p256dh
        self.auth = auth
    }

    private enum CodingKeys: String, CodingKey { case endpoint, keys }
    private enum KeyCodingKeys: String, CodingKey { case p256dh, auth }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try? container.decode(String.self, forKey: .endpoint)
        if let keys = try? container.nestedContainer(keyedBy: KeyCodingKeys.self, forKey: .keys) {
            p256dh = try? keys.decode(String.self, forKey: .p256dh)
            auth = try? keys.decode(String.self, forKey: .auth)
        }
    }
}

/// `POST /api/push/family-revoke` request. A non-string `capability` reads as
/// absent, which is the published `Invalid capability` 400.
public struct PushFamilyRevokeRequest: Decodable, Sendable, Equatable {
    public var capability: String?

    public init(capability: String? = nil) {
        self.capability = capability
    }

    private enum CodingKeys: String, CodingKey { case capability }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capability = try? container.decode(String.self, forKey: .capability)
    }
}
