// Task85 PRIVATE new file; live target absent at baseline.
import Foundation
import RaftShared

/// Node filters heterogeneous arrays, so strict [String] decoding would reject
/// valid mixed batches. Keep raw-array presence separate from filtered IDs.
public struct AttachmentURLBatchRequest: Decodable, Sendable {
    let hasNonemptyArray: Bool
    let candidateIDs: [String]
    private enum CodingKeys: String, CodingKey { case attachmentIds }
    public init(from decoder: any Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self),
              let entries = try? values.decode([JSONValue].self, forKey: .attachmentIds) else {
            hasNonemptyArray = false; candidateIDs = []; return
        }
        hasNonemptyArray = !entries.isEmpty
        candidateIDs = entries.compactMap { if case .string(let id) = $0 { return id }; return nil }
    }
}

public struct AttachmentURLBatchResponse: Encodable, JSONBodyConvertible, Sendable {
    public struct Entry: Encodable, Sendable, CustomStringConvertible {
        public let id: String
        public let url: String
        public var description: String { "AttachmentURLBatchResponse.Entry(redacted)" }
        private enum CodingKeys: String, CodingKey { case id, url, expiresAt }
        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id); try values.encode(url, forKey: .url)
            try values.encodeNil(forKey: .expiresAt)
        }
        var jsonBody: OrderedJSON {
            .object([.init("id", id), .init("url", url), .init("expiresAt", .null)])
        }
    }
    public let urls: [Entry]
    public var jsonBody: OrderedJSON { .object([.init("urls", .array(urls.map(\.jsonBody)))]) }
}

/// Transport facts for Node's proxy-URL policy, not authentication inputs.
/// The validated principal/scope must be supplied separately by owner65 flex.
public struct AttachmentURLProxyContext: Sendable, CustomStringConvertible {
    let authorization: String?
    let queryToken: String?
    let configuredServerURL: String?
    let deploymentEnvironment: String?
    let requestScheme: String
    let requestHost: String?
    let forwardedProto: String?
    let forwardedHost: String?
    public var description: String { "AttachmentURLProxyContext(redacted)" }
    public init(authorization: String?, queryToken: String?, configuredServerURL: String?,
                deploymentEnvironment: String?, requestScheme: String, requestHost: String?,
                forwardedProto: String?, forwardedHost: String?) {
        self.authorization = authorization; self.queryToken = queryToken
        self.configuredServerURL = configuredServerURL; self.deploymentEnvironment = deploymentEnvironment
        self.requestScheme = requestScheme; self.requestHost = requestHost
        self.forwardedProto = forwardedProto; self.forwardedHost = forwardedHost
    }
}

public enum AttachmentURLBatchError: DomainError, Equatable {
    case attachmentIdsRequired, invalidAttachmentIds, storageNotConfigured, resolutionFailed
    public var status: UInt {
        switch self {
        case .attachmentIdsRequired, .invalidAttachmentIds: 400
        case .storageNotConfigured: 503
        case .resolutionFailed: 500
        }
    }
    public var errorMessage: String {
        switch self {
        case .attachmentIdsRequired: "attachmentIds is required"
        case .invalidAttachmentIds: "attachmentIds must hold 1..50 valid ids"
        case .storageNotConfigured: "File storage is not configured on this server"
        case .resolutionFailed: "Failed to resolve attachment urls"
        }
    }
    public var errorCode: String? { nil }
    public var errorBody: OrderedJSON? { nil }
}
