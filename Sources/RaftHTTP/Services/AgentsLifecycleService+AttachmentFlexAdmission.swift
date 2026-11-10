import Foundation

extension AgentsLifecycleService {
    /// app.ts:578 applies this to every remaining attachment method, not only
    /// the six public serving handlers. Narrow upload-session routes run first.
    public func admitAttachmentFlex(_ input: AttachmentFlexRequest) async throws -> AttachmentFlexAdmission {
        if let token = Self.bearerToken(input.authorization) {
            if token.hasPrefix("sk_machine_") || token.hasPrefix("sk_daemon_") {
                guard let machine = machines.machine(apiKey: token) else {
                    throw AttachmentFlexAdmissionError.invalidMachineAPIKey
                }
                guard machine.legacyKeyMigratedAt == nil else {
                    throw AttachmentFlexAdmissionError.legacyMachineKeyMigrated
                }
                guard oauth.serverProfile(id: machine.serverId) != nil else {
                    throw AttachmentFlexAdmissionError.serverNoLongerExists
                }
                return AttachmentFlexAdmission(actor: .machine(machineId: machine.id),
                    serverId: machine.serverId, credentialSource: .machine, credential: input.authorization)
            }
            if token.hasPrefix("sk_computer_") {
                let machineId: String
                switch machines.computerCredential(apiKey: token) {
                case .linked(_, let linkedMachineId): machineId = linkedMachineId
                case .machineUnlinked: throw AttachmentFlexAdmissionError.linkedMachineNotFound
                case .notFound, .revoked, .keyMismatch:
                    throw AttachmentFlexAdmissionError.invalidComputerCredential
                }
                guard let machine = machines.machineCredentialIdentity(id: machineId) else {
                    throw AttachmentFlexAdmissionError.linkedMachineNotFound
                }
                guard oauth.serverProfile(id: machine.serverId) != nil else {
                    throw AttachmentFlexAdmissionError.serverNoLongerExists
                }
                // Migration invalidates the legacy key, not the linked Computer.
                return AttachmentFlexAdmission(actor: .machine(machineId: machine.machineId),
                    serverId: machine.serverId, credentialSource: .computer, credential: input.authorization)
            }
            if let userId = activeAttachmentAccessUser(input.authorization) {
                return try admitFlexUser(userId: userId, input: input, source: .authorizationJWT)
            }
        }
        // Query credentials are access JWTs only. A machine/agent query key
        // does not acquire another principal's authority.
        if let queryToken = input.queryToken,
           let userId = activeAttachmentAccessUser("Bearer \(queryToken)") {
            return try admitFlexUser(userId: userId, input: input, source: .queryJWT)
        }
        // auth.ts:122 drops empty segments but preserves case and has no method
        // check. Serving-route matching happens separately, after this gate.
        let previewPath = input.relativePath.split(separator: "/").map(String.init)
        if previewPath.count == 2, previewPath[1] == "html-preview",
           let token = input.previewToken,
           let proof = await AttachmentPreviewTokens(secret: oauth.jwtSecret).verifyForFlex(
                token, attachmentId: previewPath[0], now: dependencies.now()) {
            switch proof.actorType {
            case .user:
                return try admitFlexUser(userId: proof.actorId, input: input,
                    source: .previewToken, previewProof: proof)
            case .machine:
                guard !proof.actorId.isEmpty, !proof.serverId.isEmpty else {
                    throw AttachmentFlexAdmissionError.authenticationRequired
                }
                // This is a signed, short-lived document capability. Node does
                // not reauthenticate it as a machine API key or access session.
                return AttachmentFlexAdmission(actor: .machine(machineId: proof.actorId),
                    serverId: proof.serverId, credentialSource: .previewToken, previewProof: proof)
            }
        }
        throw AttachmentFlexAdmissionError.authenticationRequired
    }

    private func activeAttachmentAccessUser(_ authorization: String?) -> String? {
        guard let userId = sessionUserId(authorization: authorization),
              let account = profiles.account(userId: userId), account.retiredAt == nil else { return nil }
        return userId
    }

    private func admitFlexUser(userId: String, input: AttachmentFlexRequest,
        source: AttachmentFlexCredentialSource,
        previewProof: AttachmentPreviewTokens.Payload? = nil) throws -> AttachmentFlexAdmission {
        guard !userId.isEmpty else { throw AttachmentFlexAdmissionError.authenticationRequired }
        let serverId = (input.headerServerId?.isEmpty == false ? input.headerServerId : input.queryServerId) ?? ""
        guard !serverId.isEmpty else { throw AttachmentFlexAdmissionError.missingServerId }
        guard oauth.activeRegularServerMember(serverId: serverId, userId: userId) else {
            throw AttachmentFlexAdmissionError.notAMember
        }
        return AttachmentFlexAdmission(actor: .user(userId: userId), serverId: serverId,
            credentialSource: source, previewProof: previewProof,
            credential: source == .queryJWT ? input.queryToken.map { "Bearer \($0)" }
                : (source == .authorizationJWT ? input.authorization : nil))
    }

    /// Preserve the byte reader's original pre/post-I/O session/key revocation
    /// guards even though the transport now carries an explicit principal.
    private func revalidateAttachmentPrincipal(_ admission: AttachmentFlexAdmission) throws {
        if admission.credentialSource == .previewToken { return }
        switch admission.actor {
        case .user(let userId):
            guard activeAttachmentAccessUser(admission.credential) == userId else {
                throw AttachmentFlexAdmissionError.authenticationRequired
            }
        case .machine(let machineId):
            guard let token = Self.bearerToken(admission.credential) else {
                throw AttachmentFlexAdmissionError.authenticationRequired
            }
            if admission.credentialSource == .machine {
                guard let machine = machines.machine(apiKey: token), machine.id == machineId,
                      machine.serverId == admission.serverId else {
                    throw AttachmentFlexAdmissionError.invalidMachineAPIKey
                }
                guard machine.legacyKeyMigratedAt == nil else {
                    throw AttachmentFlexAdmissionError.legacyMachineKeyMigrated
                }
            } else if admission.credentialSource == .computer {
                guard case .linked(_, let currentId) = machines.computerCredential(apiKey: token),
                      currentId == machineId,
                      machines.machineCredentialIdentity(id: currentId)?.serverId == admission.serverId else {
                    throw AttachmentFlexAdmissionError.invalidComputerCredential
                }
            } else { throw AttachmentFlexAdmissionError.authenticationRequired }
            guard oauth.serverProfile(id: admission.serverId) != nil else {
                throw AttachmentFlexAdmissionError.serverNoLongerExists
            }
        }
    }

    /// app.ts:756 runs only after flex + first scope and public-router
    /// fallthrough. It authenticates the ORIGINAL header again, verifies the
    /// full live profile, then requires the HEADER server scope again.
    public func authorizeLegacyAttachmentWrite(authorization: String?, headerServerId: String?,
        flexAdmission: AttachmentFlexAdmission) throws -> String {
        let identity = try AuthCoreService(store: profiles).admitHuman(
            authorization: authorization, requirement: .verifiedProfile)
        guard let serverId = headerServerId, !serverId.isEmpty else {
            throw AttachmentFlexAdmissionError.missingServerIdHeader
        }
        guard oauth.activeRegularServerMember(serverId: serverId, userId: identity.userId) else {
            throw AttachmentFlexAdmissionError.notAMember
        }
        return serverId
    }

    /// The existing checked-store attachment read authority, with the admitted
    /// principal carried explicitly instead of reconstructing a bearer header.
    /// Re-run before and after object I/O; no bytes or success DTO are fabricated.
    func attachmentReadRecord(admission: AttachmentFlexAdmission, attachmentId: String,
        preview: Bool = false) throws -> ChannelAttachment {
        // Explicit project hardening after admission; ordinary retired JWTs
        // already fail at flex with Node's 401/35-byte response.
        if preview, case .user(let userId) = admission.actor {
            guard let account = profiles.account(userId: userId), account.retiredAt == nil else {
                throw AgentsLifecycleError.attachmentNotFound
            }
        }
        try revalidateAttachmentPrincipal(admission)
        guard ServerScope.isUUID(attachmentId) else { throw AgentsLifecycleError.invalidAttachmentId }
        guard let attachment = messages.channelAttachments[attachmentId] else {
            throw AgentsLifecycleError.attachmentNotFound
        }
        switch admission.actor {
        case .user(let userId):
            guard let account = profiles.account(userId: userId), account.retiredAt == nil,
                  oauth.activeRegularServerMember(serverId: admission.serverId, userId: userId) else {
                throw AgentsLifecycleError.attachmentNotFound
            }
            if preview {
                guard AttachmentPreviewAccessQuery(channels: channels, messages: messages, oauth: oauth, flags: agents)
                    .authority(attachment: attachment, serverId: admission.serverId, userId: userId) != nil else {
                    throw AgentsLifecycleError.attachmentNotFound
                }
            } else if !canSeeAttachment(userId: userId, serverId: admission.serverId, attachment: attachment) {
                throw AgentsLifecycleError.attachmentNotFound
            }
        case .machine:
            let authorityChannelId: String
            if let messageId = attachment.messageId {
                guard let message = messages.humanMessageRows.first(where: { $0.id == messageId }) else {
                    throw AgentsLifecycleError.attachmentNotFound
                }
                authorityChannelId = message.channelId
            } else {
                authorityChannelId = attachment.channelId
            }
            guard AttachmentMachineReadAccessQuery(channels: channels).canRead(
                authorityChannelId: authorityChannelId, serverId: admission.serverId,
                messageLinked: attachment.messageId != nil
            ) else { throw AgentsLifecycleError.attachmentNotFound }
        }
        return attachment
    }
}
