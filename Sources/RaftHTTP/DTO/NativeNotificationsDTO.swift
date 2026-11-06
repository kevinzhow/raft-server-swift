import Foundation

// Wire shapes for the native notification enrollment, device and credential
// routes, the agent attachment download surface and the integration token.
//
// Every success body owns its published member order as an `OrderedJSON` tree
// (`JSONBodyConvertible`); the strings the retired handlers concatenated by hand
// are reproduced byte for byte.

/// One notification the product wants to deliver to a native device.
public struct NativeNotificationIntent: Sendable {
    public var recipientUserId: String
    public var eventKey: String
    public var serverId: String
    public var kind: String
    public var channelId: String
    public var threadId: String?
    public var parentChannelId: String?
    public var parentMessageId: String?
    public var messageId: String
    public var title: String
    public var body: String
    public var createdAt: Date

    public init(recipientUserId: String, eventKey: String, serverId: String, kind: String, channelId: String, threadId: String?, parentChannelId: String?, parentMessageId: String?, messageId: String, title: String, body: String, createdAt: Date) {
        self.recipientUserId = recipientUserId
        self.eventKey = eventKey
        self.serverId = serverId
        self.kind = kind
        self.channelId = channelId
        self.threadId = threadId
        self.parentChannelId = parentChannelId
        self.parentMessageId = parentMessageId
        self.messageId = messageId
        self.title = title
        self.body = body
        self.createdAt = createdAt
    }
}

/// `201` of `POST /api/notifications/enrollment-grants`. The opaque grant is
/// returned once.
public struct NativeEnrollmentGrantIssued: JSONBodyConvertible, Equatable {
    public let grant: String
    public let expiresAt: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("grant", grant),
            OrderedJSONField("expiresAt", expiresAt),
        ])
    }
}

/// `201` of the enrollment exchange and the credential rotation.
public struct NativeCredentialIssued: JSONBodyConvertible, Equatable {
    public let credential: String
    public let credentialId: String
    public let deviceId: String
    public let scope: String
    public let expiresAt: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("credential", credential),
            OrderedJSONField("credentialId", credentialId),
            OrderedJSONField("deviceId", deviceId),
            OrderedJSONField("scope", scope),
            OrderedJSONField("expiresAt", expiresAt),
        ])
    }
}

/// `GET /api/notifications/devices`. Hashes, public keys and credential
/// secrets are never part of a row.
public struct NativeNotificationDeviceList: JSONBodyConvertible, Equatable {
    public struct Device: Sendable, Equatable {
        public let deviceId: String
        public let appId: String
        public let appVersion: String
        public let releaseChannel: String
        public let appInstanceId: String
        public let status: String

        var jsonBody: OrderedJSON {
            .object([
                OrderedJSONField("deviceId", deviceId),
                OrderedJSONField("appId", appId),
                OrderedJSONField("appVersion", appVersion),
                OrderedJSONField("releaseChannel", releaseChannel),
                OrderedJSONField("appInstanceId", appInstanceId),
                OrderedJSONField("attestationState", "missing"),
                OrderedJSONField("status", status),
            ])
        }
    }

    public let devices: [Device]

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("devices", .array(devices.map(\.jsonBody)))])
    }
}

/// An opened `GET /api/notifications/stream`: the user, the cursor to resume
/// from and the frames to replay first. Not JSON; the feature writes the SSE
/// body.
public struct NativeNotificationStreamStart: Sendable {
    public let userId: String
    public let cursorSeq: Int
    public let replay: [(seq: Int, frame: String)]
}

/// `GET /internal/agent-api/attachments/:attachmentId`: the stored bytes with
/// the metadata the download headers publish. Not JSON.
public struct AgentAttachmentDownload: Sendable, Equatable {
    public let bytes: Data
    public let mimeType: String
    public let filename: String
    /// The RFC 5987 encoded filename of the `Content-Disposition` header.
    public let encodedFilename: String
}

/// `GET /internal/agent-api/attachments/:attachmentId/url`.
public struct AgentAttachmentDownloadURL: JSONBodyConvertible, Equatable {
    public let url: String
    public let expiresAt: String
    public let filename: String
    public let mimeType: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("url", url),
            OrderedJSONField("expiresAt", expiresAt),
            OrderedJSONField("filename", filename),
            OrderedJSONField("mimeType", mimeType),
        ])
    }
}

/// `POST /internal/agent-api/integrations/token`.
public struct AgentIntegrationTokenIssued: JSONBodyConvertible, Equatable {
    public let accessToken: String
    public let audience: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("access_token", accessToken),
            OrderedJSONField("audience", audience),
            OrderedJSONField("expires_in", 300),
        ])
    }
}
