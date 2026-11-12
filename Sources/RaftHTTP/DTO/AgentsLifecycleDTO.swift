import Foundation
import RaftShared

// Typed contracts for the agent lifecycle surface: the agent credential
// identity, attachment upload and read, channel files, client product events,
// the Computer preflight and the runtime-provider probe.
//
// Members whose published order is not alphabetical (or that publish a literal
// `null`) conform to `JSONBodyConvertible`; the two single-member bodies are
// plain `Codable`.

// MARK: - Agent credential identity

/// `GET /internal/agent-api`: the validated credential projection.
public struct AgentApiCredentialResponse: JSONBodyConvertible, Sendable, Equatable {
    public let agentId: String
    public let agentName: String
    public let agentDisplayName: String?
    public let credentialId: String
    public let serverId: String
    public let serverRole: String?
    public let scopes: [String]

    public init(agentId: String, credentialId: String, serverId: String, scopes: [String],
                agentName: String, agentDisplayName: String?, serverRole: String?) {
        self.agentId = agentId
        self.agentName = agentName
        self.agentDisplayName = agentDisplayName
        self.credentialId = credentialId
        self.serverId = serverId
        self.serverRole = serverRole
        self.scopes = scopes
    }

    /// The identity the knowledge routes consult (no credential id).
    public var identity: AgentApiIdentityDTO {
        AgentApiIdentityDTO(agentId: agentId, serverId: serverId, scopes: scopes)
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("agentId", agentId),
            OrderedJSONField("agentName", agentName),
            OrderedJSONField("agentDisplayName", optional: agentDisplayName),
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("serverRole", optional: serverRole),
            OrderedJSONField("serverCapabilities", ServerRoleCapabilities.json(role: serverRole)),
            OrderedJSONField("credentialId", credentialId),
            OrderedJSONField("scopes", .array(scopes.map(OrderedJSON.string))),
        ])
    }
}

// MARK: - Attachment upload

/// One file of a multipart upload as the route parsed it.
public struct AttachmentUploadFile: Sendable, Equatable {
    public let filename: String
    public let mimeType: String?
    public let sizeBytes: Int

    public init(filename: String, mimeType: String?, sizeBytes: Int) {
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }
}

/// `POST /internal/agent-api/upload`: the stored row of the one uploaded file.
public struct AgentAttachmentUploadResponse: JSONBodyConvertible, Sendable, Equatable {
    public let id: String
    public let filename: String
    public let mimeType: String?
    public let sizeBytes: Int

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("filename", filename),
            OrderedJSONField("mimeType", optional: mimeType),
            OrderedJSONField("sizeBytes", sizeBytes),
            OrderedJSONField("thumbnailUrl", .null),
        ])
    }
}

/// `POST /api/attachments/upload`: complete stored attachment metadata in upload order.
public struct AttachmentUploadListResponse: JSONBodyConvertible, Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public let id: String
        public let filename: String
        public let mimeType: String
        public let sizeBytes: Int?
        public let width: Int?
        public let height: Int?
        public let thumbnailUrl: String?
        public let rasterPreviewUrl: String?

        public init(id: String, filename: String, mimeType: String? = nil, sizeBytes: Int? = nil,
                    width: Int? = nil, height: Int? = nil, thumbnailUrl: String? = nil, rasterPreviewUrl: String? = nil) {
            self.id = id
            self.filename = AttachmentPresentationRules.normalizedFilename(filename)
            self.mimeType = ChannelFileRules.resolveAttachmentMimeType(filename: filename, stored: mimeType)
            self.sizeBytes = sizeBytes
            self.width = width
            self.height = height
            self.thumbnailUrl = thumbnailUrl
            self.rasterPreviewUrl = rasterPreviewUrl
        }

        var json: OrderedJSON {
            .object([
                OrderedJSONField("id", id), OrderedJSONField("filename", filename),
                OrderedJSONField("mimeType", mimeType), OrderedJSONField("sizeBytes", optional: sizeBytes),
                OrderedJSONField("width", optional: width), OrderedJSONField("height", optional: height),
                OrderedJSONField("thumbnailUrl", optional: thumbnailUrl),
                OrderedJSONField("rasterPreviewUrl", optional: rasterPreviewUrl),
            ])
        }
    }

    public let attachments: [Row]

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("attachments", .array(attachments.map(\.json)))])
    }
}

/// `GET /api/attachments/upload-capabilities` and the agent-api twin.
public struct AttachmentUploadCapabilitiesResponse: JSONBodyConvertible, Sendable, Equatable {
    public let maxBytes: Int

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("directUploadEnabled", false),
            OrderedJSONField("directUploadThresholdBytes", .null),
            OrderedJSONField("maxBytes", maxBytes),
            OrderedJSONField("sessionExpiresInSeconds", .null),
        ])
    }
}

// MARK: - Attachment read

/// Which projection `GET /api/attachments/:id[/html-preview-url]` publishes.
public enum AttachmentReadKind: Sendable, Equatable {
    case metadata
    case htmlPreviewURL
}

/// `GET /api/attachments/:id`: the attachment's published metadata.
public struct AttachmentMetadataResponse: JSONBodyConvertible, Sendable, Equatable {
    public let id: String
    public let filename: String
    public let mimeType: String?

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("filename", filename),
            OrderedJSONField("mimeType", optional: mimeType),
        ])
    }
}

/// `GET /api/attachments/:id/html-preview-url`.
public struct AttachmentHTMLPreviewURLResponse: JSONBodyConvertible, Sendable, Equatable {
    public let url: String
    public let expiresAt: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("url", url),
            OrderedJSONField("expiresAt", expiresAt),
        ])
    }
}

/// One of the two bodies `readAttachment` answers with.
public enum AttachmentReadResponse: JSONBodyConvertible, Sendable, Equatable {
    case metadata(AttachmentMetadataResponse)
    case htmlPreviewURL(AttachmentHTMLPreviewURLResponse)

    public var jsonBody: OrderedJSON {
        switch self {
        case .metadata(let body): return body.jsonBody
        case .htmlPreviewURL(let body): return body.jsonBody
        }
    }
}

/// `GET /api/attachments/:id?token=…`: the stored document published as an
/// `application/octet-stream` body. The text is not JSON; it travels through
/// `OrderedJSON.raw` so `respond` publishes the stored bytes unchanged under
/// the octet-stream header policy.
public struct AttachmentStreamBody: JSONBodyConvertible, Sendable, Equatable {
    public let body: String

    public var jsonBody: OrderedJSON { .raw(body) }

    public var headers: ResponseHeaders {
        .exact(["Content-Type": "application/octet-stream"])
    }
}

/// `GET /api/attachments/:id/html-preview`: the stored document with the
/// bridge appended and the headers the preview publishes. It is streamed
/// without a `Content-Length` (the stored size would truncate it), so the
/// feature, not `respond`, writes it.
public struct AttachmentHTMLPreview: Sendable, Equatable {
    public let body: String
    public let headers: [String: String]
}

// MARK: - Channel files

/// `GET /api/channels/:channelId/files`.
public struct ChannelFilesResponse: JSONBodyConvertible, Sendable, Equatable {
    public struct Uploader: Sendable, Equatable {
        public let type: String
        public let id: String
        public let name: String?
        public let displayName: String?
    }

    public struct Source: Sendable, Equatable {
        public let type: String
        public let channelId: String
        public let parentMessageId: String?
        public let parentMessageShortId: String?
    }

    public struct File: Sendable, Equatable {
        public let id: String
        public let messageId: String
        public let channelId: String
        public let filename: String
        public let mimeType: String
        public let sizeBytes: Int?
        public let width: Int?
        public let height: Int?
        public let thumbnailUrl: String?
        public let createdAt: String
        public let uploader: Uploader
        public let source: Source
    }

    public let files: [File]
    public let nextCursor: String?

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("files", .array(files.map(\.jsonBody))),
            OrderedJSONField("nextCursor", optional: nextCursor),
        ])
    }
}

extension ChannelFilesResponse.File {
    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("messageId", messageId),
            OrderedJSONField("channelId", channelId),
            OrderedJSONField("filename", filename),
            OrderedJSONField("mimeType", mimeType),
            OrderedJSONField("sizeBytes", optional: sizeBytes),
            OrderedJSONField("width", optional: width),
            OrderedJSONField("height", optional: height),
            OrderedJSONField("thumbnailUrl", optional: thumbnailUrl),
            OrderedJSONField("createdAt", createdAt),
            OrderedJSONField("uploader", .object([
                OrderedJSONField("type", uploader.type),
                OrderedJSONField("id", uploader.id),
                OrderedJSONField("name", optional: uploader.name),
                OrderedJSONField("displayName", optional: uploader.displayName),
            ])),
            OrderedJSONField("source", .object([
                OrderedJSONField("type", source.type),
                OrderedJSONField("channelId", source.channelId),
                OrderedJSONField("parentMessageId", optional: source.parentMessageId),
                OrderedJSONField("parentMessageShortId", optional: source.parentMessageShortId),
            ])),
        ])
    }
}

// MARK: - Client product events

/// `GET /api/product-events/config`.
public struct ClientEventsConfigResponse: Codable, Sendable, Equatable {
    public let clientEventsAllowed: Bool
}

/// `POST /api/product-events/batch`: how many events were stored.
public struct ClientEventsAcceptedResponse: Codable, Sendable, Equatable {
    public let accepted: Int
}

/// `POST /api/product-events/batch` request body.
///
/// The retired handler cast the parsed object member by member: a member of the
/// wrong type read as absent, while a body that was not a JSON object failed as
/// a whole. The root keeps its members as a `JSONValue` tree and the service
/// projects each one with those cast rules.
public struct ClientEventsBatchRequest: Decodable, Sendable, Equatable {
    public let members: [String: JSONValue]

    public init(members: [String: JSONValue] = [:]) {
        self.members = members
    }

    public init(from decoder: any Decoder) throws {
        guard case .object(let members) = try JSONValue(from: decoder) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a JSON object"
            ))
        }
        self.members = members
    }
}

// MARK: - Computer preflight and provider probe

/// `POST /internal/computer/preflight`.
public struct ComputerPreflightResponse: JSONBodyConvertible, Sendable, Equatable {
    public let surface: InternalSurfaceSnapshot
    public let serverId: String
    public let serverSlug: String
    public let computerId: String
    public let computerName: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("surfaceVersion", surface.surfaceVersion),
            OrderedJSONField("claimedPrefixes", .array(surface.claimedPrefixes.map(OrderedJSON.string))),
            OrderedJSONField("registeredPrincipals", .array(surface.registeredPrincipals.map(OrderedJSON.string))),
            // The surface entries keep the snapshot's own member renderer; the
            // array delimiters stay here so an empty surface still prints `[]`.
            OrderedJSONField("computerSurface", .array([.raw(surface.computerSurfaceJSON())])),
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("serverSlug", serverSlug),
            OrderedJSONField("principal", .object([
                OrderedJSONField("kind", "computer"),
                OrderedJSONField("id", computerId),
                OrderedJSONField("name", computerName),
            ])),
        ])
    }
}

/// `GET /api/runtime-providers/:kind`.
public struct RuntimeProviderProbeResponse: JSONBodyConvertible, Sendable, Equatable {
    public let available: Bool

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("kind", "antiproton"),
            OrderedJSONField("available", available),
        ])
    }
}
