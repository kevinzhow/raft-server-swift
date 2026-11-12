import Foundation
import RaftObjectStorage
import Synchronization

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

/// The bounded upload's pre-I/O admission and storage capture. It contains no
/// bytes and no request body; the caller writes objects between phases.
private struct AttachmentUploadPlan: Sendable {
    let admission: AttachmentUploadAdmission
    let storage: (any AttachmentObjectStoring)?
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
        authorization: String?, serverId: String, channelId: String, files: [AttachmentUploadContent],
        transaction: AttachmentTransactionMode = .legacy
    ) async throws -> AttachmentUploadListResponse {
        try await storeAttachmentContents(
            actor: .human(authorization: authorization, serverId: serverId), channelId: channelId,
            files: files, transaction: transaction
        )
    }

    public func uploadMachineAttachmentContent(
        authorization: String?, agentId: String, channelId: String, file: AttachmentUploadContent,
        transaction: AttachmentTransactionMode = .legacy
    ) async throws -> AttachmentUploadListResponse {
        try await storeAttachmentContents(
            actor: .machine(authorization: authorization, agentId: agentId), channelId: channelId,
            files: [file], transaction: transaction
        )
    }

    public func uploadAgentAttachmentContent(
        authorization: String?, channelId: String, file: AttachmentUploadContent,
        transaction: AttachmentTransactionMode = .legacy
    ) async throws -> AgentAttachmentUploadResponse {
        let result = try await storeAttachmentContents(
            actor: .agent(authorization: authorization), channelId: channelId,
            files: [file], transaction: transaction
        )
        guard let row = result.attachments.first else { throw AttachmentContentError.uploadFailed }
        return AgentAttachmentUploadResponse(
            id: row.id, filename: row.filename, mimeType: file.mimeType, sizeBytes: file.bytes.count
        )
    }

    /// Authorize before object I/O and again before returning plaintext. The
    /// projection and object reference must still describe the same attachment.
    /// Each authorization/capture pair is one short committed phase; the object
    /// read happens between them outside every writer permit.
    public func attachmentContent(
        authorization: String?, serverId: String?, attachmentId: String,
        admission: AttachmentFlexAdmission? = nil,
        transaction: AttachmentTransactionMode = .legacy
    ) async throws -> AttachmentBinaryContent {
        let captured = try await transaction.committedValue {
            if let admission {
                _ = try attachmentReadRecord(admission: admission, attachmentId: attachmentId)
            } else {
                _ = try readAttachment(authorization: authorization, serverId: serverId, attachmentId: attachmentId)
            }
            return try attachmentReadSnapshot(attachmentId)
        }
        let bytes = try await loadAttachmentBytes(captured, failure: .downloadFailed)
        let current = try await transaction.committedValue {
            if let admission {
                _ = try attachmentReadRecord(admission: admission, attachmentId: attachmentId)
            } else {
                _ = try readAttachment(authorization: authorization, serverId: serverId, attachmentId: attachmentId)
            }
            let current = try attachmentReadSnapshot(attachmentId)
            guard current.hasSameBinding(as: captured) else {
                throw AgentsLifecycleError.attachmentNotFound
            }
            return current
        }
        guard bytes.count == captured.row.sizeBytes else { throw AttachmentContentError.downloadFailed }
        return AttachmentBinaryContent(
            bytes: bytes, filename: current.row.filename, mimeType: current.row.mimeType
        )
    }

    /// Preview admission runs on both sides of object I/O. All captured byte and
    /// authorization bindings must still refer to the same projection afterwards.
    func attachmentPreviewContent(
        attachmentId: String,
        transaction: AttachmentTransactionMode = .legacy,
        authorize: @escaping @Sendable (ChannelAttachment) throws -> AttachmentPreviewAdmission
    ) async throws -> AttachmentBinaryContent {
        let pre = try await transaction.committedValue {
            let snapshot = try attachmentReadSnapshot(attachmentId)
            let admission = try authorize(snapshot.row)
            return (snapshot, admission)
        }
        let captured = pre.0
        let admission = pre.1
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
        let current = try await transaction.committedValue {
            let current = try attachmentReadSnapshot(attachmentId)
            guard current.hasSameBinding(as: captured) else { throw AgentsLifecycleError.attachmentNotFound }
            let currentAdmission = try authorize(current.row)
            guard currentAdmission == admission else { throw AgentsLifecycleError.attachmentNotFound }
            return current
        }
        guard bytes.count == count else { throw AttachmentContentError.previewFailed }
        return AttachmentBinaryContent(
            bytes: bytes, filename: current.row.filename, mimeType: admission.mimeType
        )
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
        actor: AttachmentUploadActor, channelId: String, files: [AttachmentUploadContent],
        transaction: AttachmentTransactionMode
    ) async throws -> AttachmentUploadListResponse {
        switch transaction {
        case .legacy:
            return try await storeAttachmentContentsLegacy(
                actor: actor, channelId: channelId, files: files
            )
        case .bounded(let port):
            return try await storeAttachmentContentsBounded(
                actor: actor, channelId: channelId, files: files, port: port
            )
        }
    }

    /// Every excluded caller (internal agent/machine uploads and direct
    /// fixtures) keeps the original outer-transaction behavior.
    private func storeAttachmentContentsLegacy(
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
        return AttachmentUploadListResponse(attachments: zip(ids, files).map {
            .init(id: $0.0, filename: $0.1.filename, mimeType: $0.1.mimeType, sizeBytes: $0.1.bytes.count)
        })
    }

    /// Bounded upload: admit/capture, object writes, re-admit/compare, rows.
    /// Cleanup happens only when metadata is definitely not committed. An
    /// unknown commit never deletes the just-written object.
    private func storeAttachmentContentsBounded(
        actor: AttachmentUploadActor, channelId: String, files: [AttachmentUploadContent],
        port: any AttachmentTransactionPort
    ) async throws -> AttachmentUploadListResponse {
        let planOutcome = await port.commit {
            do {
                let admission = try admitAttachmentUpload(actor: actor, channelId: channelId, files: files)
                let requiresDurable = messages.withState { $0.requiresDurableAttachmentStorage }
                let storage = messages.withState { $0.attachmentObjectStorage }
                guard storage != nil || !requiresDurable else {
                    throw AttachmentContentError.uploadsNotConfigured
                }
                return .ready(AttachmentUploadPlan(admission: admission, storage: storage))
            } catch let error as any DomainError {
                return .refused(error)
            } catch {
                return .failed(error)
            }
        }
        let plan = try planOutcome.value()

        let ids = files.map { _ in UUID().uuidString.lowercased() }
        var references: [String: AttachmentObjectReference] = [:]
        do {
            if let storage = plan.storage {
                for (id, file) in zip(ids, files) {
                    references[id] = try await storage.put(attachmentID: id, bytes: file.bytes)
                }
            }
        } catch {
            // The puts failed before any metadata write was attempted.
            await deleteReferences(references, storage: plan.storage)
            if let refusal = error as? any DomainError { throw refusal }
            throw AttachmentContentError.uploadFailed
        }

        // Set immediately before the row publication. Nothing can throw after
        // this point, so a false value proves no attachment metadata was written.
        let writtenReferences = references
        let metadataWriteStarted = Mutex(false)
        let outcome = await port.commit {
            do {
                guard try admitAttachmentUpload(actor: actor, channelId: channelId, files: files)
                    == plan.admission else {
                    throw AttachmentContentError.cannotWriteChannel
                }
                let now = dependencies.now()
                metadataWriteStarted.withLock { $0 = true }
                messages.withState { state in
                    for (id, file) in zip(ids, files) {
                        state.channelAttachments[id] = ChannelAttachment(
                            id: id, channelId: channelId, uploaderId: plan.admission.uploaderId,
                            filename: file.filename, messageId: nil, messagePosition: nil,
                            mimeType: file.mimeType, sizeBytes: file.bytes.count,
                            uploaderType: plan.admission.uploaderType,
                            createdAt: now, storageKey: writtenReferences[id]?.objectKey
                        )
                        if let reference = writtenReferences[id] {
                            state.attachmentObjectReferences[id] = reference
                        } else {
                            state.developmentAttachmentBytes[id] = file.bytes
                        }
                    }
                }
                return .ready(AttachmentUploadListResponse(
                    attachments: zip(ids, files).map {
                        .init(id: $0.0, filename: $0.1.filename, mimeType: $0.1.mimeType, sizeBytes: $0.1.bytes.count)
                    }
                ))
            } catch let error as any DomainError {
                return .refused(error)
            } catch {
                return .failed(error)
            }
        }

        switch outcome {
        case .committed(let response):
            return response
        case .notCommitted(.refused(let error)):
            // The closure guarantees no attachment row was written before a
            // refusal, and the runtime has committed any admission side effects.
            await deleteReferences(references, storage: plan.storage)
            throw error
        case .notCommitted(.failed(let error)):
            if !metadataWriteStarted.withLock({ $0 }) {
                await deleteReferences(references, storage: plan.storage)
            }
            throw error
        case .notCommitted(.unavailable), .notCommitted(.cancelledBeforeStart):
            // The callback never started, so no attachment row can exist.
            await deleteReferences(references, storage: plan.storage)
            throw AttachmentPersistenceUnavailable()
        case .outcomeUnknown:
            // SQL may have committed. Never delete the object.
            throw AttachmentPersistenceUnavailable()
        }
    }

    private func deleteReferences(
        _ references: [String: AttachmentObjectReference], storage: (any AttachmentObjectStoring)?
    ) async {
        guard let storage else { return }
        for reference in references.values { try? await storage.delete(reference) }
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
