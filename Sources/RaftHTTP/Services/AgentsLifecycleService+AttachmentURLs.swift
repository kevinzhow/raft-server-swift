// PRIVATE follow-up over frozen85. Only pure URL presentation is shared.
import Foundation

extension AgentsLifecycleService {
    public func attachmentBatchURLs(admission: AttachmentFlexAdmission, body: AttachmentURLBatchRequest?,
                                    proxy: AttachmentURLProxyContext) throws -> AttachmentURLBatchResponse {
        guard admission.credentialSource != .previewToken else { throw AttachmentFlexAdmissionError.authenticationRequired }
        guard let body, body.hasNonemptyArray else { throw AttachmentURLBatchError.attachmentIdsRequired }
        var seen: Set<String> = []
        let requested = body.candidateIDs.filter { ServerScope.isUUID($0) && seen.insert($0).inserted }
        guard !requested.isEmpty, requested.count <= 50 else { throw AttachmentURLBatchError.invalidAttachmentIds }
        guard messages.withState({ $0.attachmentObjectStorage != nil }) else { throw AttachmentURLBatchError.storageNotConfigured }
        var urls: [AttachmentURLBatchResponse.Entry] = []
        var projected: Set<String> = []
        for rawID in requested {
            let id = rawID.lowercased()
            guard projected.insert(id).inserted else { continue }
            let attachment: ChannelAttachment
            do { attachment = try attachmentReadRecord(admission: admission, attachmentId: id, preview: true) }
            catch AgentsLifecycleError.attachmentNotFound { continue }
            let url = try AttachmentProxyURLPolicy.makeURL(attachmentId: attachment.id,
                serverId: admission.serverId, context: proxy, disposition: .inline)
            urls.append(.init(id: attachment.id, url: url))
        }
        return .init(urls: urls)
    }
}

enum AttachmentProxyDisposition: String { case attachment, inline }

/// Presentation only. Neither authenticates nor changes attachment authority.
/// Both callers supply owner65's admitted server and the original HTTP scalars.
enum AttachmentProxyURLPolicy {
    static func singleDisposition(filename: String, mimeType: String?, disposition: String?, download: String?) -> AttachmentProxyDisposition? {
        if disposition == "attachment" || download == "1" { return .attachment }
        guard disposition == "inline" else { return nil }
        let normalized = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let resolved: String
        if !normalized.isEmpty && normalized != "application/octet-stream" { resolved = normalized }
        else {
            let ext = filename.lastIndex(of: ".").map { String(filename[$0...]).lowercased() } ?? ""
            resolved = previewFilenameMimes[ext] ?? normalized
        }
        let first = resolved.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        let base = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return inlineMediaMimes.contains(base) ? .inline : nil
    }

    static func makeURL(attachmentId: String, serverId: String, context: AttachmentURLProxyContext,
                        disposition: AttachmentProxyDisposition?) throws -> String {
        let base: String
        if context.deploymentEnvironment == "slockdev" {
            let scheme = firstForwardedValue(context.forwardedProto) ?? context.requestScheme
            guard let host = firstForwardedValue(context.forwardedHost) ?? context.requestHost, !host.isEmpty else {
                throw AttachmentURLBatchError.resolutionFailed
            }
            base = "\(scheme)://\(host)"
        } else if let configured = context.configuredServerURL, !configured.isEmpty { base = configured }
        else {
            guard let host = context.requestHost, !host.isEmpty else { throw AttachmentURLBatchError.resolutionFailed }
            base = "\(context.requestScheme)://\(host)"
        }
        guard var url = URLComponents(string: "\(base)/api/attachments/\(attachmentId)"),
              ["http", "https"].contains(url.scheme ?? ""), url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AttachmentURLBatchError.resolutionFailed
        }
        var query: [(String, String)] = []
        // Preserve Node's original header priority even if query JWT won auth.
        if let authorization = context.authorization, authorization.hasPrefix("Bearer ") {
            query.append(("token", String(authorization.dropFirst(7))))
        } else if let token = context.queryToken { query.append(("token", token)) }
        query.append(("serverId", serverId))
        if let disposition { query.append(("disposition", disposition.rawValue)) }
        url.percentEncodedQuery = query.map { formEncode($0.0) + "=" + formEncode($0.1) }.joined(separator: "&")
        guard let value = url.string else { throw AttachmentURLBatchError.resolutionFailed }
        return value
    }

    private static func firstForwardedValue(_ value: String?) -> String? {
        guard let value, let first = value.split(separator: ",", omittingEmptySubsequences: false).first else { return nil }
        let trimmed = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func formEncode(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 48...57, 65...90, 97...122, 42, 45, 46, 95: return String(UnicodeScalar(byte))
            case 32: return "+"
            default: return String(format: "%%%02X", byte)
            }
        }.joined()
    }
    private static let previewFilenameMimes = [
        ".pdf": "application/pdf", ".mp4": "video/mp4", ".webm": "video/webm", ".mov": "video/quicktime",
        ".mp3": "audio/mpeg", ".wav": "audio/wav", ".m4a": "audio/mp4", ".aac": "audio/aac",
        ".ogg": "audio/ogg", ".oga": "audio/ogg", ".opus": "audio/opus", ".weba": "audio/webm", ".flac": "audio/flac",
    ]
    private static let inlineMediaMimes: Set<String> = [
        "application/pdf", "video/mp4", "video/webm", "video/quicktime", "audio/mpeg", "audio/mp3",
        "audio/wav", "audio/x-wav", "audio/wave", "audio/aac", "audio/mp4", "audio/x-m4a",
        "audio/ogg", "audio/opus", "audio/webm", "audio/flac", "audio/x-flac",
    ]
}
