import Foundation
import RaftObjectStorage

private enum AttachmentUploadActor: Sendable {
    case human(authorization: String?, serverId: String)
    case machine(authorization: String?, agentId: String)
    case agent(authorization: String?)
}

private struct AttachmentUploadAdmission: Sendable, Equatable {
    let serverId: String
    let channelId: String
    let uploaderId: String
    let uploaderType: String
}

enum AttachmentPreviewAuthority: Sendable, Equatable {
    case user(AttachmentPreviewAccessQuery.Authority)
    case machine(serverId: String, channelId: String)
}

struct AttachmentPreviewAdmission: Sendable, Equatable {
    let mimeType: String
    let authority: AttachmentPreviewAuthority
}

private struct AttachmentReadSnapshot: Sendable {
    let row: ChannelAttachment
    let reference: AttachmentObjectReference?
    let storage: (any AttachmentObjectStoring)?
    let development: Data?
    let requiresDurable: Bool
    let messageChannelId: String?

    func hasSameBinding(as other: Self) -> Bool {
        reference == other.reference && messageChannelId == other.messageChannelId
            && requiresDurable == other.requiresDurable
            && (reference != nil || development == other.development)
            && row.id == other.row.id && row.channelId == other.row.channelId
            && row.messageId == other.row.messageId && row.messagePosition == other.row.messagePosition
            && row.uploaderId == other.row.uploaderId && row.uploaderType == other.row.uploaderType
            && row.filename == other.row.filename && row.mimeType == other.row.mimeType
            && row.sizeBytes == other.row.sizeBytes && row.storageKey == other.row.storageKey
            && row.createdAt == other.row.createdAt
    }
}

extension AgentsLifecycleService {
    /// Prefix flex and its first server scope already ran. Recheck the
    /// later full-profile/header-only server gate before multipart decoding.
    public func authorizeHumanAttachmentUpload(
        authorization: String?, headerServerId: String?, flexAdmission: AttachmentFlexAdmission
    ) throws -> String {
        try authorizeLegacyAttachmentWrite(authorization: authorization,
            headerServerId: headerServerId, flexAdmission: flexAdmission)
    }

    public func uploadAttachmentContents(
        authorization: String?, serverId: String, channelId: String, files: [AttachmentUploadContent]
    ) async throws -> AttachmentUploadListResponse {
        try await storeAttachmentContents(
            actor: .human(authorization: authorization, serverId: serverId), channelId: channelId, files: files
        )
    }

    public func uploadMachineAttachmentContent(
        authorization: String?, agentId: String, channelId: String, file: AttachmentUploadContent
    ) async throws -> AttachmentUploadListResponse {
        try await storeAttachmentContents(
            actor: .machine(authorization: authorization, agentId: agentId), channelId: channelId, files: [file]
        )
    }

    public func uploadAgentAttachmentContent(
        authorization: String?, channelId: String, file: AttachmentUploadContent
    ) async throws -> AgentAttachmentUploadResponse {
        let result = try await storeAttachmentContents(
            actor: .agent(authorization: authorization), channelId: channelId, files: [file]
        )
        guard let row = result.attachments.first else { throw AttachmentContentError.uploadFailed }
        return AgentAttachmentUploadResponse(
            id: row.id, filename: row.filename, mimeType: file.mimeType, sizeBytes: file.bytes.count
        )
    }

    /// Authorize before object I/O and again before returning plaintext. The
    /// projection and object reference must still describe the same attachment.
    public func attachmentContent(
        authorization: String?, serverId: String?, attachmentId: String,
        admission: AttachmentFlexAdmission? = nil
    ) async throws -> AttachmentBinaryContent {
        if let admission {
            _ = try attachmentReadRecord(admission: admission, attachmentId: attachmentId)
        } else {
            _ = try readAttachment(authorization: authorization, serverId: serverId, attachmentId: attachmentId)
        }
        let captured = try attachmentReadSnapshot(attachmentId)
        let bytes = try await loadAttachmentBytes(captured, failure: .downloadFailed)
        if let reference = captured.reference,
           messages.withState({ $0.attachmentObjectReferences[attachmentId] }) != reference {
            throw AgentsLifecycleError.attachmentNotFound
        }
        if let admission {
            _ = try attachmentReadRecord(admission: admission, attachmentId: attachmentId)
        } else {
            _ = try readAttachment(authorization: authorization, serverId: serverId, attachmentId: attachmentId)
        }
        guard bytes.count == captured.row.sizeBytes else { throw AttachmentContentError.downloadFailed }
        return AttachmentBinaryContent(bytes: bytes, filename: captured.row.filename, mimeType: captured.row.mimeType)
    }

    /// Preview admission runs on both sides of object I/O. All captured byte and
    /// authorization bindings must still refer to the same projection afterwards.
    func attachmentPreviewContent(
        attachmentId: String, authorize: @Sendable (ChannelAttachment) throws -> AttachmentPreviewAdmission
    ) async throws -> AttachmentBinaryContent {
        let captured = try attachmentReadSnapshot(attachmentId)
        let admission = try authorize(captured.row)
        let maximum = 200 * 1024 * 1024
        guard let count = captured.row.sizeBytes, count >= 0, count <= maximum else {
            throw AttachmentContentError.previewFailed
        }
        if let reference = captured.reference {
            guard reference.byteCount == count, captured.row.storageKey == reference.objectKey else {
                throw AttachmentContentError.previewFailed
            }
        }
        let bytes = try await loadAttachmentBytes(captured, failure: .previewFailed)
        let current = try attachmentReadSnapshot(attachmentId)
        guard current.hasSameBinding(as: captured) else { throw AgentsLifecycleError.attachmentNotFound }
        let currentAdmission = try authorize(current.row)
        guard currentAdmission == admission else { throw AgentsLifecycleError.attachmentNotFound }
        guard bytes.count == count else { throw AttachmentContentError.previewFailed }
        return AttachmentBinaryContent(bytes: bytes, filename: current.row.filename, mimeType: currentAdmission.mimeType)
    }

    private func attachmentReadSnapshot(_ id: String) throws -> AttachmentReadSnapshot {
        let snapshot: AttachmentReadSnapshot? = messages.withState { state in
            guard let row = state.channelAttachments[id] else { return nil }
            return AttachmentReadSnapshot(row: row, reference: state.attachmentObjectReferences[id],
                storage: state.attachmentObjectStorage, development: state.developmentAttachmentBytes[id],
                requiresDurable: state.requiresDurableAttachmentStorage,
                messageChannelId: row.messageId.flatMap { id in state.humanMessageRows.first { $0.id == id }?.channelId })
        }
        guard let snapshot else { throw AgentsLifecycleError.attachmentNotFound }
        return snapshot
    }

    private func loadAttachmentBytes(
        _ captured: AttachmentReadSnapshot, failure: AttachmentContentError
    ) async throws -> Data {
        if let reference = captured.reference {
            guard let storage = captured.storage else { throw AttachmentContentError.downloadsNotConfigured }
            do { return try await storage.get(reference) }
            catch AttachmentStorageError.notFound { throw AgentsLifecycleError.attachmentNotFound }
            catch { throw failure }
        }
        guard !captured.requiresDurable else { throw AttachmentContentError.downloadsNotConfigured }
        guard let bytes = captured.development else { throw AgentsLifecycleError.attachmentNotFound }
        return bytes
    }

    private func storeAttachmentContents(
        actor: AttachmentUploadActor, channelId: String, files: [AttachmentUploadContent]
    ) async throws -> AttachmentUploadListResponse {
        let admission = try admitAttachmentUpload(actor: actor, channelId: channelId, files: files)
        let storage = messages.withState { $0.attachmentObjectStorage }
        if storage == nil, messages.withState({ $0.requiresDurableAttachmentStorage }) {
            throw AttachmentContentError.uploadsNotConfigured
        }
        let ids = files.map { _ in UUID().uuidString.lowercased() }
        var references: [String: AttachmentObjectReference] = [:]
        do {
            if let storage {
                for (id, file) in zip(ids, files) {
                    references[id] = try await storage.put(attachmentID: id, bytes: file.bytes)
                }
            }
            guard try admitAttachmentUpload(actor: actor, channelId: channelId, files: files) == admission else {
                throw AttachmentContentError.cannotWriteChannel
            }
        } catch {
            // Only uploads whose failure is known here are removed. A later
            // ambiguous database commit must not delete a possibly committed file.
            if let storage {
                for reference in references.values { try? await storage.delete(reference) }
            }
            if let refusal = error as? any DomainError { throw refusal }
            throw AttachmentContentError.uploadFailed
        }
        let now = dependencies.now()
        messages.withState { state in
            for (id, file) in zip(ids, files) {
                state.channelAttachments[id] = ChannelAttachment(
                    id: id, channelId: channelId, uploaderId: admission.uploaderId,
                    filename: file.filename, messageId: nil, messagePosition: nil,
                    mimeType: file.mimeType, sizeBytes: file.bytes.count, uploaderType: admission.uploaderType,
                    createdAt: now, storageKey: references[id]?.objectKey
                )
                if let reference = references[id] {
                    state.attachmentObjectReferences[id] = reference
                } else {
                    state.developmentAttachmentBytes[id] = file.bytes
                }
            }
        }
        return AttachmentUploadListResponse(attachments: zip(ids, files).map { .init(id: $0.0, filename: $0.1.filename) })
    }

    private func admitAttachmentUpload(
        actor: AttachmentUploadActor, channelId: String, files: [AttachmentUploadContent]
    ) throws -> AttachmentUploadAdmission {
        try requireUploadsEnabled()
        let uploaderId: String
        let uploaderType: String
        let serverId: String
        switch actor {
        case .human(let authorization, let requestedServer):
            uploaderId = try requireUser(authorization)
            uploaderType = "user"
            serverId = requestedServer
            guard oauth.memberRole(serverId: serverId, userId: uploaderId) != nil else {
                throw AgentsLifecycleError.notAMember
            }
        case .agent(let authorization):
            guard let credential = agentCredential(authorization),
                  let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted,
                  credential.scopes.contains("send") || credential.scopes.contains("write") else {
                throw AgentsLifecycleError.capabilityNotAuthorized
            }
            uploaderId = agent.id
            uploaderType = "agent"
            serverId = agent.serverId
        case .machine(let authorization, let agentId):
            guard let token = Self.bearerToken(authorization) else { throw AgentsLifecycleError.unauthorized }
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else { throw AgentsLifecycleError.agentMissing }
            guard let machine = machines.machines.first(where: { $0.apiKey == token }),
                  machine.serverId == agent.serverId, agents.agentMachineIds[agentId] == machine.id else {
                throw AgentsLifecycleError.forbidden
            }
            uploaderId = agentId
            uploaderType = "agent"
            serverId = agent.serverId
        }
        guard !files.isEmpty else { throw AttachmentContentError.noFiles }
        guard files.count <= 10 else { throw AgentsLifecycleError.tooManyFiles }
        guard !files.contains(where: { $0.bytes.isEmpty }) else { throw AgentsLifecycleError.emptyFile }
        let maximum = uploadLimit(serverId: serverId)
        guard !files.contains(where: { $0.bytes.count > maximum }) else {
            throw AgentsLifecycleError.fileTooLarge(maxBytes: maximum)
        }
        guard !channelId.isEmpty else { throw AttachmentContentError.channelIdRequired }
        guard let channel = channels.postableChannels[channelId], channel.serverId == serverId, channel.deletedAt == nil else {
            throw AttachmentContentError.cannotWriteChannel
        }
        let parentMember = channel.kind == "thread" && channel.parentChannelId.flatMap {
            channels.postableChannels[$0]?.memberIds.contains(uploaderId)
        } == true
        guard channel.kind == "channel" || channel.memberIds.contains(uploaderId) || parentMember
                || (uploaderType == "agent" && oauth.channelAgentIds(channelId: channelId).contains(uploaderId)) else {
            throw AttachmentContentError.cannotWriteChannel
        }
        let parentArchived = channel.parentChannelId.flatMap { oauth.channelArchivedAt(id: $0) } != nil
        guard !channel.archived, oauth.channelArchivedAt(id: channelId) == nil, !parentArchived else {
            throw AttachmentContentError.channelArchived
        }
        return AttachmentUploadAdmission(serverId: serverId, channelId: channelId, uploaderId: uploaderId, uploaderType: uploaderType)
    }
}
