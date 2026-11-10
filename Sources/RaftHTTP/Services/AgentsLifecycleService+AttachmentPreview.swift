import Foundation

extension AgentsLifecycleService {
    private var attachmentPreviewTokens: AttachmentPreviewTokens { .init(secret: oauth.jwtSecret) }

    /// Dedicated async mint; unrelated metadata reads remain synchronous.
    public func attachmentHTMLPreviewURL(
        attachmentId: String, admission: AttachmentFlexAdmission
    ) async throws -> AttachmentHTMLPreviewURLResponse {
        guard admission.credentialSource != .previewToken else {
            throw AttachmentFlexAdmissionError.authenticationRequired
        }
        guard ServerScope.isUUID(attachmentId) else { throw AgentsLifecycleError.invalidAttachmentId }
        let row = try attachmentReadRecord(admission: admission, attachmentId: attachmentId, preview: true)
        let initial = try authorizePreview(admission: admission, attachment: row)
        let reference = messages.withState { $0.attachmentObjectReferences[attachmentId] }
        let now = dependencies.now()
        let identity = previewIdentity(admission.actor)
        let token: String
        do {
            token = try await attachmentPreviewTokens.mint(attachmentId: attachmentId, serverId: admission.serverId,
                actorId: identity.id, actorType: identity.type, now: now)
        } catch { throw AttachmentContentError.previewURLFailed }
        let current = try attachmentReadRecord(admission: admission, attachmentId: attachmentId, preview: true)
        guard try authorizePreview(admission: admission, attachment: current) == initial,
              messages.withState({ $0.attachmentObjectReferences[attachmentId] }) == reference else {
            throw AgentsLifecycleError.attachmentNotFound
        }
        return AttachmentHTMLPreviewURLResponse(
            url: "/api/attachments/\(attachmentId)/html-preview?serverId=\(admission.serverId)&previewToken=\(token)",
            expiresAt: DateText.isoString(now.addingTimeInterval(300)))
    }

    /// Direct scoped capability entry. The shared verifier completes before any
    /// attachment projection lookup; the HTTP Flex path supplies the same proof.
    public func attachmentHTMLPreview(
        attachmentId: String, serverId: String, previewToken rawPreviewToken: String?, bearerQuery: String?
    ) async throws -> AttachmentBinaryContent {
        // Match Node's truthy preview-token check without trimming whitespace
        // or discarding the separate scalar bearer-query presence check.
        let previewToken = rawPreviewToken.flatMap { $0.isEmpty ? nil : $0 }
        guard ServerScope.isUUID(attachmentId) else { throw AgentsLifecycleError.invalidAttachmentId }
        guard let previewToken else {
            if bearerQuery != nil { throw AttachmentContentError.bearerPreviewForbidden }
            throw AgentsLifecycleError.unauthorized
        }
        guard let proof = await attachmentPreviewTokens.verify(previewToken, attachmentId: attachmentId,
            serverId: serverId, now: dependencies.now()) else { throw AgentsLifecycleError.unauthorized }
        return try await attachmentHTMLPreview(attachmentId: attachmentId,
            admission: previewAdmission(proof), previewToken: previewToken, bearerQuery: bearerQuery)
    }

    /// Consumes the request-local admission and immutable proof from Flex. A
    /// proof already verified by middleware is not cryptographically reverified.
    public func attachmentHTMLPreview(
        attachmentId: String, admission: AttachmentFlexAdmission, previewToken rawPreviewToken: String?, bearerQuery: String?
    ) async throws -> AttachmentBinaryContent {
        // Match Node's truthy preview-token check without trimming whitespace
        // or discarding the separate scalar bearer-query presence check.
        let previewToken = rawPreviewToken.flatMap { $0.isEmpty ? nil : $0 }
        guard ServerScope.isUUID(attachmentId) else { throw AgentsLifecycleError.invalidAttachmentId }
        let proof: AttachmentPreviewTokens.Payload?
        if let verified = admission.previewProof {
            guard verified.isValid(attachmentId: attachmentId, serverId: verified.serverId, now: dependencies.now()) else {
                throw AgentsLifecycleError.unauthorized
            }
            // Flex's user server scope is external input. A fully signed proof
            // for another scope is a leaf refusal after visibility, not a new
            // authentication failure before the attachment lookup.
            proof = verified.serverId == admission.serverId ? verified : nil
        } else if let previewToken {
            proof = await attachmentPreviewTokens.verify(previewToken, attachmentId: attachmentId,
                serverId: admission.serverId, now: dependencies.now())
        } else { proof = nil }
        if admission.credentialSource == .previewToken, admission.previewProof == nil, proof == nil {
            throw AgentsLifecycleError.unauthorized
        }
        let actorAdmission = proof.map(previewAdmission) ?? admission
        return try await attachmentPreviewContent(attachmentId: attachmentId) { attachment in
            if let proof, !proof.isValid(attachmentId: attachmentId, serverId: admission.serverId, now: dependencies.now()) {
                throw AgentsLifecycleError.unauthorized
            }
            _ = try attachmentReadRecord(admission: actorAdmission, attachmentId: attachmentId, preview: true)
            // Node cloaks visibility before these errors for an independently
            // admitted ordinary principal. MIME admission follows these leaf
            // refusals, so readable non-HTML cannot change their 403 response.
            if previewToken != nil, proof == nil { throw AttachmentContentError.invalidPreviewToken }
            if previewToken == nil, bearerQuery != nil { throw AttachmentContentError.bearerPreviewForbidden }
            return try authorizePreview(admission: actorAdmission, attachment: attachment)
        }
    }

    private func previewAdmission(_ proof: AttachmentPreviewTokens.Payload) -> AttachmentFlexAdmission {
        let actor: AttachmentFlexActor
        switch proof.actorType {
        case .user: actor = .user(userId: proof.actorId)
        case .machine: actor = .machine(machineId: proof.actorId)
        }
        return AttachmentFlexAdmission(actor: actor, serverId: proof.serverId,
            credentialSource: .previewToken, previewProof: proof)
    }

    private func previewIdentity(_ actor: AttachmentFlexActor) -> (id: String, type: AttachmentPreviewTokens.ActorType) {
        switch actor {
        case .user(let id): (id, .user)
        case .machine(let id): (id, .machine)
        }
    }

    private func authorizePreview(
        admission: AttachmentFlexAdmission, attachment: ChannelAttachment
    ) throws -> AttachmentPreviewAdmission {
        guard oauth.serverProfile(id: admission.serverId) != nil else { throw AgentsLifecycleError.attachmentNotFound }
        let authority: AttachmentPreviewAuthority
        switch admission.actor {
        case .user(let id):
            // The common read owner checks the live account and principal.
            guard let current = AttachmentPreviewAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: agents)
                .authority(attachment: attachment, serverId: admission.serverId, userId: id) else {
                throw AgentsLifecycleError.attachmentNotFound
            }
            authority = .user(current)
        case .machine:
            // The shared read owner enforces live server/channel/projection
            // authority. A signed preview capability is not tied to a current key.
            _ = try attachmentReadRecord(admission: admission, attachmentId: attachment.id, preview: true)
            authority = .machine(serverId: admission.serverId, channelId: attachment.channelId)
        }
        return AttachmentPreviewAdmission(mimeType: try previewMIME(attachment), authority: authority)
    }

    private func previewMIME(_ attachment: ChannelAttachment) throws -> String {
        let normalized = attachment.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let resolved: String
        if normalized.isEmpty || normalized == "application/octet-stream" {
            let ext = attachment.filename.lastIndex(of: ".").map { String(attachment.filename[$0...]).lowercased() } ?? ""
            resolved = [".html", ".htm"].contains(ext) ? "text/html" : normalized
        } else { resolved = normalized }
        guard resolved.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "text/html" else {
            throw AttachmentContentError.notPreviewableHTML
        }
        return resolved
    }
}
