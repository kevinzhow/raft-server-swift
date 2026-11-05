import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {








    func deviceSurfaceDisabled() -> HTTPReply? {
        if Self.deviceLoginEnabled(deviceLoginGate) { return nil }
        return Self.json(404, "{\"error\":\"Device login is not enabled\",\"code\":\"device_login_disabled\"}")
    }

    func deviceVerification(userCode: String) -> (uri: String, complete: String)? {
        let trimmed = appURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        let uri = "\(base)/login/device"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        let encoded = userCode.addingPercentEncoding(withAllowedCharacters: allowed) ?? userCode
        return (uri, "\(uri)?user_code=\(encoded)")
    }

    func makeUserCode() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var chars = ""
        for _ in 0..<8 {
            chars.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return "\(chars.prefix(4))-\(chars.dropFirst(4))"
    }




    /// Opens one session family. The caller already holds `lock`.
    func openSessionLocked(userId: String) -> (accessToken: String, refreshToken: String) {
        let familyId = UUID().uuidString.lowercased()
        sessionFamilies[familyId] = SessionFamily(userId: userId, revokedAt: nil)
        let accessToken = Self.token()
        let refreshToken = Self.token()
        sessions[refreshToken] = LiveSession(userId: userId, familyId: familyId)
        accessTokens[accessToken] = userId
        accessTokenFamilies[accessToken] = familyId
        return (accessToken, refreshToken)
    }

    /// Retirement auth keeps the access token after the account is retired. A missing bearer is the invalid-token body.
    func retirementActor(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let id = accessTokens[token]
        lock.unlock()
        return id
    }






    func refreshLocked(refreshToken: String, attemptId: String?, installationId: String?) -> RefreshOutcome {
        if let attemptId, let installationId {
            return durableRefreshLocked(refreshToken: refreshToken, attemptId: attemptId, installationId: installationId)
        }
        guard let live = sessions[refreshToken], !revokedFamilies.contains(live.familyId) else {
            return .rejected
        }
        sessions.removeValue(forKey: refreshToken)
        predecessorFamilies[Self.sha256(refreshToken)] = live.familyId
        let successor = Self.token()
        sessions[successor] = live
        let accessToken = Self.token()
        accessTokens[accessToken] = live.userId
        accessTokenFamilies[accessToken] = live.familyId
        return .rotated(IssuedRefresh(accessToken: accessToken, userId: live.userId), successor)
    }

    func durableRefreshLocked(refreshToken: String, attemptId: String, installationId: String) -> RefreshOutcome {
        let hash = Self.sha256(refreshToken)
        if let live = sessions.removeValue(forKey: refreshToken) {
            if revokedFamilies.contains(live.familyId) {
                return .rejected
            }
            let successor = Self.token()
            sessions[successor] = live
            let ciphertext = Self.sealSuccessor(successor)
            rotationReceipts[hash] = RotationReceipt(
                attemptId: attemptId,
                installationId: installationId,
                userId: live.userId,
                familyId: live.familyId,
                successor: successor,
                ciphertext: ciphertext,
                expiresAt: Date(timeIntervalSinceNow: 15 * 60)
            )
            let accessToken = Self.token()
            accessTokens[accessToken] = live.userId
            accessTokenFamilies[accessToken] = live.familyId
            return .rotated(IssuedRefresh(accessToken: accessToken, userId: live.userId), successor)
        }
        guard let receipt = rotationReceipts[hash] else { return .rejected }
        if receipt.attemptId != attemptId || receipt.installationId != installationId { return .rejected }
        if receipt.expiresAt <= Date() || revokedFamilies.contains(receipt.familyId) { return .rejected }
        let accessToken = Self.token()
        accessTokens[accessToken] = receipt.userId
        accessTokenFamilies[accessToken] = receipt.familyId
        return .rotated(IssuedRefresh(accessToken: accessToken, userId: receipt.userId), receipt.successor)
    }

    /// Primary env wins when it parses to at least one URI. Otherwise the legacy list replaces the defaults. An empty parse falls through.
    func configuredMobileReturnURIs() -> Set<String> {
        let primary = Self.parseConfiguredMobileReturnURIs(mobileOAuthReturnURI)
        if !primary.isEmpty { return primary }
        let legacy = Self.parseConfiguredMobileReturnURIs(mobileOAuthAllowedReturnURIs)
        if !legacy.isEmpty { return legacy }
        return Self.defaultMobileReturnURIs
    }



















    public func removeChannelMemberForTesting(channelId: String, userId: String) {
        oauth.removeChannelHuman(channelId: channelId, userId: userId)
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(userId)
        lock.unlock()
    }

    public func setChannelGuestVisibleForTesting(channelId: String, visible: Bool) {
        lock.lock()
        guestVisibleChannels[channelId] = visible
        lock.unlock()
    }

    public func setChannelGuestJoinableForTesting(channelId: String, joinable: Bool) {
        lock.lock()
        guestJoinableChannels[channelId] = joinable
        lock.unlock()
    }

    func guestCanSeeScopeLocked(_ scopeId: String) -> Bool {
        if postableChannels[scopeId]?.kind == "thread",
           let parentId = postableChannels[scopeId]?.parentChannelId {
            return guestVisibleChannels[parentId] ?? true
        }
        return guestVisibleChannels[scopeId] ?? true
    }

    public func setChannelPostablePrivateForTesting(channelId: String) {
        lock.lock()
        postableChannels[channelId]?.kind = "private"
        lock.unlock()
    }

    public func agentApiIdentity(authorization: String?) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        guard let credential = agentCredentials[token], credential.revokedAt == nil else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let agentId = credential.agentId
        let credentialId = credential.id
        let scopes = credential.scopes.sorted()
        lock.unlock()
        recordAgentCredentialUse(token: token)
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let scopesJSON = scopes.map { jsonString($0) }.joined(separator: ",")
        return Self.json(200, "{\"agentId\":\(jsonString(agentId)),\"credentialId\":\(jsonString(credentialId)),\"serverId\":\(jsonString(agent.serverId)),\"scopes\":[\(scopesJSON)]}")
    }

    public func uploadAgentAttachmentIdless(
        authorization: String?,
        channelId: String,
        filename: String,
        mimeType: String?,
        sizeBytes: Int,
        bytes: Data
    ) -> HTTPReply {
        let gate = (ProcessInfo.processInfo.environment["ATTACHMENT_UPLOAD_ENABLED"] ?? "true")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["false", "0", "off"].contains(gate) {
            return Self.json(503, "{\"error\":\"File uploads are disabled on this server\",\"errorCode\":\"ATTACHMENT_UPLOAD_DISABLED\"}")
        }
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted,
              credential.scopes.contains("send") || credential.scopes.contains("write")
        else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
        }
        lock.lock()
        let channel = postableChannels[channelId]
        lock.unlock()
        guard let channel, channel.serverId == agent.serverId, channel.deletedAt == nil,
              channel.kind == "channel"
                || channel.memberIds.contains(agent.id)
                || oauth.channelAgentIds(channelId: channelId).contains(agent.id)
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard sizeBytes > 0 else {
            return Self.json(400, "{\"error\":\"Empty files are not allowed\"}")
        }
        let plan = oauth.serverProfile(id: agent.serverId)?.plan ?? "free"
        let maxBytes = plan == "free" ? 50 * 1024 * 1024 : 200 * 1024 * 1024
        if sizeBytes > maxBytes {
            return Self.json(413, "{\"error\":\"Max 50MB per file\",\"errorCode\":\"ATTACHMENT_TOO_LARGE\",\"maxBytes\":\(maxBytes)}")
        }
        let id = addChannelAttachment(
            channelId: channelId,
            uploaderId: agent.id,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes
        )
        lock.lock()
        channelAttachments[id]?.uploaderType = "agent"
        agentAttachmentBytes[id] = bytes
        lock.unlock()
        let mimeJSON = mimeType.map(jsonString) ?? "null"
        return Self.json(200, "{\"id\":\(jsonString(id)),\"filename\":\(jsonString(filename)),\"mimeType\":\(mimeJSON),\"sizeBytes\":\(sizeBytes),\"thumbnailUrl\":null}")
    }

    public func agentAttachmentUploadCapabilities(authorization: String?) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted,
              let profile = oauth.serverProfile(id: agent.serverId)
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let limit = profile.plan == "free" ? 50 * 1024 * 1024 : 90 * 1024 * 1024
        return Self.json(200, "{\"directUploadEnabled\":false,\"directUploadThresholdBytes\":null,\"maxBytes\":\(limit),\"sessionExpiresInSeconds\":null}")
    }

    public func uploadAttachments(
        authorization: String?,
        serverId: String,
        channelId: String,
        files: [(filename: String, mimeType: String?, sizeBytes: Int)]
    ) -> HTTPReply {
        let gate = (ProcessInfo.processInfo.environment["ATTACHMENT_UPLOAD_ENABLED"] ?? "true")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["false", "0", "off"].contains(gate) {
            return Self.json(503, "{\"error\":\"File uploads are disabled on this server\",\"errorCode\":\"ATTACHMENT_UPLOAD_DISABLED\"}")
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let channel = postableChannels[channelId]
        lock.unlock()
        guard let channel, channel.serverId == serverId, channel.deletedAt == nil,
              channel.kind == "channel" || channel.memberIds.contains(userId)
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard files.count <= 10 else {
            return Self.json(400, "{\"error\":\"Max 10 files per message\"}")
        }
        for file in files where file.sizeBytes <= 0 {
            return Self.json(400, "{\"error\":\"Empty files are not allowed\"}")
        }
        let plan = oauth.serverProfile(id: serverId)?.plan ?? "free"
        let maxBytes = plan == "free" ? 50 * 1024 * 1024 : 200 * 1024 * 1024
        if files.contains(where: { $0.sizeBytes > maxBytes }) {
            return Self.json(413, "{\"error\":\"Max 50MB per file\",\"errorCode\":\"ATTACHMENT_TOO_LARGE\",\"maxBytes\":\(maxBytes)}")
        }
        var rows: [String] = []
        for file in files {
            let id = addChannelAttachment(
                channelId: channelId,
                uploaderId: userId,
                filename: file.filename,
                mimeType: file.mimeType,
                sizeBytes: file.sizeBytes
            )
            rows.append("{\"id\":\(jsonString(id)),\"filename\":\(jsonString(file.filename))}")
        }
        return Self.json(200, "{\"attachments\":[\(rows.joined(separator: ","))]}")
    }

    public func uploadAgentAttachment(
        authorization: String?,
        agentId: String,
        channelId: String,
        filename: String,
        mimeType: String?,
        sizeBytes: Int
    ) -> HTTPReply {
        let gate = (ProcessInfo.processInfo.environment["ATTACHMENT_UPLOAD_ENABLED"] ?? "true")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["false", "0", "off"].contains(gate) {
            return Self.json(503, "{\"error\":\"File uploads are disabled on this server\",\"errorCode\":\"ATTACHMENT_UPLOAD_DISABLED\"}")
        }
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let machine = machines.first { $0.apiKey == token }
        let agent = oauth.agentRuntimeInfo(id: agentId)
        let assigned = agentMachineIds[agentId]
        let channel = postableChannels[channelId]
        lock.unlock()
        guard let agent, !agent.deleted else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard let machine, machine.serverId == agent.serverId, assigned == machine.id else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let channel, channel.serverId == agent.serverId, channel.deletedAt == nil,
              channel.kind == "channel" || channel.memberIds.contains(agentId) || oauth.channelAgentIds(channelId: channelId).contains(agentId)
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard sizeBytes > 0 else {
            return Self.json(400, "{\"error\":\"Empty files are not allowed\"}")
        }
        let plan = oauth.serverProfile(id: agent.serverId)?.plan ?? "free"
        let maxBytes = plan == "free" ? 50 * 1024 * 1024 : 200 * 1024 * 1024
        if sizeBytes > maxBytes {
            return Self.json(413, "{\"error\":\"Max 50MB per file\",\"errorCode\":\"ATTACHMENT_TOO_LARGE\",\"maxBytes\":\(maxBytes)}")
        }
        let id = addChannelAttachment(channelId: channelId, uploaderId: agentId, filename: filename, mimeType: mimeType, sizeBytes: sizeBytes)
        return Self.json(200, "{\"attachments\":[{\"id\":\(jsonString(id)),\"filename\":\(jsonString(filename))}]}")
    }

    public func attachmentUploadSessionCreate(authorization: String?, serverId: String) -> HTTPReply {
        guard sessionUserId(authorization: authorization) != nil else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: sessionUserId(authorization: authorization) ?? "") != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        return Self.json(403, "{\"code\":\"UPLOAD_FORBIDDEN\",\"message\":\"The member cannot upload to this channel.\",\"retryable\":false}")
    }

    public func attachmentUploadSessionMissing(authorization: String?, uploadId: String) -> HTTPReply {
        guard sessionUserId(authorization: authorization) != nil else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        return Self.json(404, "{\"code\":\"UPLOAD_SESSION_NOT_FOUND\",\"message\":\"Upload session not found.\",\"retryable\":false}")
    }

    public func attachmentUploadCapabilities(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let profile = oauth.serverProfile(id: serverId), oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let limit = profile.plan == "free" ? 50 * 1024 * 1024 : 90 * 1024 * 1024
        return Self.json(200, "{\"directUploadEnabled\":false,\"directUploadThresholdBytes\":null,\"maxBytes\":\(limit),\"sessionExpiresInSeconds\":null}")
    }

    public func addChannelAttachmentForTesting(channelId: String, id: String, uploaderId: String, filename: String) {
        lock.lock()
        channelAttachments[id] = ChannelAttachment(id: id, channelId: channelId, uploaderId: uploaderId, filename: filename, messageId: nil, messagePosition: nil)
        lock.unlock()
    }

    public func addChannelFileForTesting(
        channelId: String,
        id: String,
        uploaderId: String,
        uploaderType: String = "user",
        messageId: String,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        createdAt: Date,
        thumbnailKey: String? = nil
    ) {
        lock.lock()
        channelAttachments[id] = ChannelAttachment(
            id: id,
            channelId: channelId,
            uploaderId: uploaderId,
            filename: filename,
            messageId: messageId,
            messagePosition: 0,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            uploaderType: uploaderType,
            createdAt: createdAt,
            thumbnailKey: thumbnailKey
        )
        lock.unlock()
    }

    /// Visibility projection for callers that already hold the directory lock.
    func visibleAttachmentUnlocked(userId: String, serverId: String?, attachment: ChannelAttachment) -> Bool {
        let effectiveChannelId = attachment.messageId.flatMap { messageId in
            humanMessageRows.first { $0.id == messageId }?.channelId
        } ?? attachment.channelId
        if let channel = postableChannels[effectiveChannelId],
           channel.serverId == serverId,
           channel.deletedAt == nil {
            return channel.kind == "channel" || channel.memberIds.contains(userId)
        }
        guard let serverId, attachment.messageId != nil else { return false }
        return oauth.memberRole(serverId: serverId, userId: userId) != nil
    }

    func visibleAttachment(userId: String, serverId: String?, attachment: ChannelAttachment) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A linked attachment follows its message into a joint canonical
        // channel; an unlinked draft stays on its upload channel.
        let effectiveChannelId = attachment.messageId.flatMap { messageId in
            humanMessageRows.first { $0.id == messageId }?.channelId
        } ?? attachment.channelId
        if let channel = postableChannels[effectiveChannelId],
           channel.serverId == serverId,
           channel.deletedAt == nil {
            return channel.kind == "channel" || channel.memberIds.contains(userId)
        }
        guard let serverId, let messageId = attachment.messageId else { return false }
        let canonicalId: String?
        if let link = jointProjections.first(where: { $0.localChannelId == effectiveChannelId }) {
            canonicalId = link.canonicalChannelId
        } else if jointProjections.contains(where: { $0.canonicalChannelId == effectiveChannelId }) {
            canonicalId = effectiveChannelId
        } else {
            canonicalId = nil
        }
        guard let canonicalId,
              humanMessageRows.contains(where: { $0.id == messageId && $0.channelId == canonicalId }),
              let localId = jointLocalChannelIdLocked(canonicalChannelId: canonicalId, serverId: serverId, userId: userId),
              let local = postableChannels[localId],
              local.deletedAt == nil
        else { return false }
        return true
    }






    /// A probe on a channel the caller cannot currently read. Missing and
    /// hidden answer the same way; receiver-owned residue is acknowledged
    /// with a distinct 403 so the caller can clear Activity.
    func channelProbeAccessLocked(channelId: String, serverId: String, userId: String) -> ChannelProbeAccess {
        guard let channel = postableChannels[channelId], channel.serverId == serverId else { return .hidden }
        if channel.kind == "channel"
            || channel.memberIds.contains(userId)
            || oauth.channelType(id: channelId) == "channel"
            || oauth.isChannelParticipant(channelId: channelId, userId: userId)
            || (channel.kind == "thread" && threadFollows["\(serverId)\n\(userId)\n\(channelId)"] != nil) {
            return .allowed
        }
        let residue = inboxResiduesForTesting.contains("\(userId)\n\(channelId)")
            || inboxFactStore.all().contains {
                $0.receiverType == "user" && $0.receiverId == userId && $0.channelId == channelId
            }
            || oauth.channelUnreadInfo(channelId: channelId, userId: userId).maxReadSeq > 0
        return residue ? .residue : .hidden
    }

    public func channelFiles(
        authorization: String?,
        serverId: String,
        channelId: String,
        limit rawLimit: String? = nil,
        cursor rawCursor: String? = nil
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let access = channelProbeAccessLocked(channelId: channelId, serverId: serverId, userId: userId)
        let channel = postableChannels[channelId]
        lock.unlock()
        if access == .residue {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard access == .allowed, let channel, channel.deletedAt == nil else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let kind = channel.kind
        let isMember = channel.memberIds.contains(userId)
        guard kind == "channel" || isMember else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let limit = Self.channelFilesLimit(rawLimit)
        let cursor: (createdAt: Date, id: String)?
        if let rawCursor, !rawCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let decoded = Self.channelFilesBase64URLDecode(rawCursor),
                  let object = (try? JSONSerialization.jsonObject(with: Data(decoded.utf8))) as? [String: Any],
                  let createdAtRaw = object["createdAt"] as? String,
                  let createdAt = Self.isoDate(createdAtRaw),
                  let id = object["id"] as? String
            else {
                return Self.json(400, "{\"error\":\"Invalid cursor\"}")
            }
            cursor = (createdAt, id)
        } else {
            cursor = nil
        }

        lock.lock()
        var scopeChannels: Set<String> = [channelId]
        for (id, candidate) in postableChannels
        where candidate.serverId == serverId && candidate.kind == "thread"
            && candidate.parentChannelId == channelId && candidate.deletedAt == nil {
            scopeChannels.insert(id)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var files: [ChannelAttachment] = []
        for attachment in channelAttachments.values {
            guard scopeChannels.contains(attachment.channelId) else { continue }
            if let messageId = attachment.messageId,
               !humanMessageRows.contains(where: { $0.id == messageId && $0.channelId == attachment.channelId }) {
                continue
            }
            if let cursor {
                if attachment.createdAt > cursor.createdAt { continue }
                if attachment.createdAt == cursor.createdAt && attachment.id >= cursor.id { continue }
            }
            files.append(attachment)
        }
        files.sort { left, right in
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id > right.id
        }
        let page = Array(files.prefix(limit))
        let nextCursor: String?
        if files.count > limit, let last = page.last {
            let encoded = "{\"createdAt\":\(jsonString(formatter.string(from: last.createdAt))),\"id\":\(jsonString(last.id))}"
            nextCursor = Self.channelFilesBase64URLEncode(encoded)
        } else {
            nextCursor = nil
        }
        let rows = page.map { attachment -> String in
            let source = postableChannels[attachment.channelId]
            let isThread = source?.kind == "thread"
            let parentMessageId = isThread ? source?.parentMessageId : nil
            let parentJSON = parentMessageId.map(jsonString) ?? "null"
            let parentShort = parentMessageId.map { jsonString(String($0.prefix(8))) } ?? "null"
            let uploaderName: String?
            let uploaderDisplay: String?
            if attachment.uploaderType == "agent" {
                let agent = oauth.agentRuntimeInfo(id: attachment.uploaderId)
                uploaderName = agent?.name
                uploaderDisplay = agent?.displayName
            } else if attachment.uploaderType == "user" {
                let account = accounts.values.first { $0.id == attachment.uploaderId }
                uploaderName = account?.name
                uploaderDisplay = account?.name
            } else {
                uploaderName = nil
                uploaderDisplay = nil
            }
            let nameJSON = uploaderName.map(jsonString) ?? "null"
            let displayJSON = (uploaderDisplay ?? uploaderName).map(jsonString) ?? "null"
            let mime = Self.channelFileMimeType(filename: attachment.filename, stored: attachment.mimeType)
            let size = attachment.sizeBytes.map(String.init) ?? "null"
            let width = attachment.width.map(String.init) ?? "null"
            let height = attachment.height.map(String.init) ?? "null"
            let thumbnail = attachment.thumbnailKey.map { _ in jsonString("/api/attachments/\(attachment.id)/thumbnail") } ?? "null"
            return "{\"id\":\(jsonString(attachment.id)),\"messageId\":\(jsonString(attachment.messageId ?? "")),\"channelId\":\(jsonString(attachment.channelId)),\"filename\":\(jsonString(attachment.filename)),\"mimeType\":\(jsonString(mime)),\"sizeBytes\":\(size),\"width\":\(width),\"height\":\(height),\"thumbnailUrl\":\(thumbnail),\"createdAt\":\(jsonString(formatter.string(from: attachment.createdAt))),\"uploader\":{\"type\":\(jsonString(attachment.uploaderType == "agent" ? "agent" : "user")),\"id\":\(jsonString(attachment.uploaderId)),\"name\":\(nameJSON),\"displayName\":\(displayJSON)},\"source\":{\"type\":\(jsonString(isThread ? "thread" : "channel")),\"channelId\":\(jsonString(attachment.channelId)),\"parentMessageId\":\(parentJSON),\"parentMessageShortId\":\(parentShort)}}"
        }
        lock.unlock()
        let nextJSON = nextCursor.map(jsonString) ?? "null"
        return Self.json(200, "{\"files\":[\(rows.joined(separator: ","))],\"nextCursor\":\(nextJSON)}")
    }

    public func attachmentQueryTokenStream(attachmentId: String, token: String, serverId: String?) -> HTTPReply {
        guard ServerScope.isUUID(attachmentId) else {
            return Self.json(400, "{\"code\":\"invalid_attachment_id\",\"error\":\"Invalid attachment id\"}")
        }
        guard let userId = sessionUserId(authorization: "Bearer \(token)") else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"X-Server-Id header is required\"}")
        }
        if !oauth.memberIds(serverId: serverId).isEmpty,
           oauth.memberRole(serverId: serverId, userId: userId) == nil {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let attachment = channelAttachments[attachmentId]
        lock.unlock()
        guard let attachment, visibleAttachment(userId: userId, serverId: serverId, attachment: attachment) else {
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        if let body = attachmentPreviewBody?(attachmentId) {
            return HTTPReply(status: 200, headers: ["Content-Type": "application/octet-stream"], body: body)
        }
        return Self.json(404, "{\"error\":\"Attachment not found\"}")
    }

    public func attachmentHTMLPreview(
        attachmentId: String,
        serverId: String,
        previewToken: String?,
        bearerQuery: String?
    ) -> HTTPReply {
        if bearerQuery != nil {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let previewToken,
              validateAttachmentPreviewToken(previewToken, attachmentId: attachmentId, serverId: serverId) != nil
        else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let original = attachmentPreviewBody?(attachmentId) else {
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        // The stored document streams unmodified with the bridge appended, and
        // no Content-Length because the stored size would truncate it. An
        // attachment-supplied CSP meta tag keeps governing the document: the
        // bridge goes immediately before it, since meta CSP only applies to the
        // content parsed after it.
        var body = original
        let bridge = AttachmentPreviewBridge.script
        if let metaRange = Self.cspMetaTagRange(in: original) {
            body = String(original[..<metaRange.lowerBound]) + bridge + String(original[metaRange.lowerBound...])
        } else {
            body += bridge
        }
        let origin = ProcessInfo.processInfo.environment["APP_URL"] ?? "http://127.0.0.1:4173"
        var reply = HTTPReply(status: 200, headers: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": "frame-ancestors 'self' \(origin); connect-src 'none'; form-action 'none'; object-src 'none'",
            "Cache-Control": "private, no-store",
        ], body: body)
        reply.headers.removeValue(forKey: "X-Frame-Options")
        reply.headers.removeValue(forKey: "Content-Length")
        return reply
    }

    /// Range of the attachment's own CSP meta tag, if it supplies one.
    static func cspMetaTagRange(in html: String) -> Range<String.Index>? {
        let lower = html.lowercased()
        guard let metaStart = lower.range(of: "<meta"),
              let csp = lower.range(of: "content-security-policy", range: metaStart.lowerBound..<lower.endIndex),
              let tagEnd = lower.range(of: ">", range: csp.upperBound..<lower.endIndex)
        else { return nil }
        return metaStart.lowerBound..<tagEnd.upperBound
    }

    public func readAttachment(authorization: String?, serverId: String?, attachmentId: String, kind: String) -> HTTPReply {
        guard ServerScope.isUUID(attachmentId) else {
            return Self.json(400, "{\"code\":\"invalid_attachment_id\",\"error\":\"Invalid attachment id\"}")
        }
        if let authorization, authorization.hasPrefix("Bearer sk_computer_") {
            let key = String(authorization.dropFirst("Bearer ".count))
            lock.lock()
            let computerServer = computers.first { $0.apiKey == key && $0.revokedAt == nil }?.serverId
            let attachment = channelAttachments[attachmentId]
            let channelServer = attachment.flatMap { channelAttachments[$0.id] }.flatMap { postableChannels[$0.channelId]?.serverId }
            lock.unlock()
            guard let computerServer else {
                return Self.json(401, "{\"error\":\"Unauthorized\"}")
            }
            let requested = serverId ?? computerServer
            guard requested == computerServer else {
                return Self.json(403, "{\"error\":\"Not a member of this server\"}")
            }
            guard attachment != nil, channelServer == requested else {
                return Self.json(404, "{\"error\":\"Attachment not found\"}")
            }
            return Self.json(200, "{\"id\":\(jsonString(attachment!.id)),\"filename\":\(jsonString(attachment!.filename)),\"mimeType\":\(attachment!.mimeType.map { jsonString($0) } ?? "null")}")
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let retired = accounts.values.first { $0.id == userId }?.retiredAt != nil
        lock.unlock()
        guard !retired else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"X-Server-Id header is required\"}")
        }
        if !oauth.memberIds(serverId: serverId).isEmpty,
           oauth.memberRole(serverId: serverId, userId: userId) == nil {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let attachment = channelAttachments[attachmentId]
        lock.unlock()
        guard let attachment, visibleAttachment(userId: userId, serverId: serverId, attachment: attachment) else {
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        switch kind {
        case "url":
            return Self.json(200, "{\"url\":\"\(jsonString("/api/attachments/\(attachmentId)"))\"}")
        case "html-preview-url":
            let previewToken = mintAttachmentPreviewToken(attachmentId: attachmentId, serverId: serverId, actorId: userId)
            let url = "/api/attachments/\(attachmentId)/html-preview?serverId=\(serverId)&previewToken=\(previewToken)"
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expiresAt = formatter.string(from: Date().addingTimeInterval(300))
            return Self.json(200, "{\"url\":\(jsonString(url)),\"expiresAt\":\(jsonString(expiresAt))}")
        default:
            return Self.json(200, "{\"id\":\(jsonString(attachment.id)),\"filename\":\(jsonString(attachment.filename)),\"mimeType\":\(attachment.mimeType.map { jsonString($0) } ?? "null")}")
        }
    }


    /// The user id behind a live access token. A missing or unknown bearer is nil.
    public func sessionUserId(authorization: String?) -> String? {
        if case .user(let id) = authorize(authorization) { return id }
        return nil
    }

    /// Access-token identity used by the socket layer. The family id scopes
    /// revocation to the connection family that owns the token.
    public func sessionIdentity(accessToken: String) -> (userId: String, familyId: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let userId = accessTokens[accessToken] else { return nil }
        return (userId, accessTokenFamilies[accessToken])
    }

    /// Resolve a `push/family-revoke` capability without consuming it.
    public func familyRevokeTarget(capability: String) -> (userId: String, familyId: String)? {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let familyId = sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key,
              let family = sessionFamilies[familyId]
        else { return nil }
        return (family.userId, familyId)
    }

    public func setShareUsageData(userId: String, value: Bool?) {
        lock.lock()
        if let key = accounts.first(where: { $0.value.id == userId })?.key {
            accounts[key]?.shareUsageData = value
        }
        lock.unlock()
    }

    public func recordedProductEvents(subjectId: String) -> [RecordedProductEvent] {
        productEventStore.productEvents(subjectId: subjectId)
    }

    /// `GET /api/product-events/config`.
    public func clientEventsConfig(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let allowed = accounts.values.first(where: { $0.id == userId })?.shareUsageData == true
        lock.unlock()
        return Self.json(200, "{\"clientEventsAllowed\":\(allowed)}")
    }

    public func recordedClientEvents(serverId: String) -> [ClientEventRecord] {
        productEventStore.clientEvents(serverId: serverId)
    }

    /// `POST /api/product-events/batch`.
    public func clientEventsBatch(
        authorization: String?,
        serverId: String,
        userAgent: String,
        country: String,
        body: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let allowed = accounts.values.first(where: { $0.id == userId })?.shareUsageData == true
        lock.unlock()
        guard allowed else {
            return Self.json(202, "{\"accepted\":0}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              object["source"] as? String == "web",
              let events = object["events"] as? [[String: Any]], !events.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid event batch\"}")
        }
        let appVersion = object["app_version"] as? String
        if let appVersion, appVersion.wholeMatch(of: /^[0-9]+\.[0-9]+\.[0-9]+$/) == nil {
            return Self.json(400, "{\"error\":\"Invalid app_version\"}")
        }
        let uuidPattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        let now = Date()
        var rows: [ClientEventRecord] = []
        var batchSeen: Set<String> = []
        for event in events {
            guard let uuid = event["uuid"] as? String, uuid.wholeMatch(of: uuidPattern) != nil,
                  let name = event["event"] as? String,
                  let timestamp = event["timestamp"] as? String,
                  let parsed = formatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp),
                  let session = event["client_session_id"] as? String,
                  session.wholeMatch(of: uuidPattern) != nil,
                  let properties = event["properties"] as? [String: Any]
            else {
                return Self.json(400, "{\"error\":\"Invalid event batch\"}")
            }
            if now.timeIntervalSince(parsed) > 7 * 24 * 60 * 60 { continue }
            if productEventStore.containsSeenClientEvent(uuid) || !batchSeen.insert(uuid).inserted { continue }
            var sanitized: [String: Any] = [:]
            let allowedKeys: Set<String>
            if name == "activity_open" {
                allowedKeys = ["from"]
            } else if name == "activity_mark" {
                allowedKeys = ["action"]
            } else {
                continue
            }
            guard Set(properties.keys).isSubset(of: allowedKeys) else { continue }
            for (key, value) in properties {
                if let text = value as? String { sanitized[key] = text }
            }
            for (key, value) in Self.deviceContext(userAgent: userAgent, country: country) {
                sanitized[key] = value
            }
            let propertiesJSON: String
            if let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]) {
                propertiesJSON = String(decoding: data, as: UTF8.self)
            } else {
                propertiesJSON = "{}"
            }
            let analyticsId: String
            lock.lock()
            if let existing = analyticsIds[userId] {
                analyticsId = existing
            } else {
                let minted = UUID().uuidString.lowercased()
                analyticsIds[userId] = minted
                analyticsId = minted
            }
            lock.unlock()
            rows.append(ClientEventRecord(
                event: name,
                analyticsId: analyticsId,
                serverId: serverId,
                source: "web",
                sessionId: session,
                appVersion: appVersion,
                propertiesJSON: propertiesJSON
            ))
        }
        let seenIDs: [String] = events.compactMap { event in
            guard let uuid = event["uuid"] as? String, uuid.wholeMatch(of: uuidPattern) != nil else { return nil }
            return uuid
        }
        productEventStore.appendClientEvents(rows, seenIDs: seenIDs)
        return Self.json(202, "{\"accepted\":\(rows.count)}")
    }



    func agentAuthority(_ authorization: String?, agentId: String) -> AgentAuthority {
        guard let userId = sessionUserId(authorization: authorization) else {
            return .denied(Self.json(401, "{\"error\":\"Unauthorized\"}"))
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted else {
            return .denied(Self.json(404, "{\"error\":\"Agent not found\"}"))
        }
        guard let role = oauth.memberRole(serverId: info.serverId, userId: userId) else {
            return .denied(Self.json(403, "{\"error\":\"Not a member of this server\"}"))
        }
        if role == "owner" || role == "admin" || info.creatorUserId == userId {
            return .allowed(userId: userId, role: role, info: info)
        }
        return .denied(Self.json(403, "{\"error\":\"Forbidden\"}"))
    }

    /// The upstream server capability matrix for the two lifecycle verbs this
    /// file answers: members hold `controlAgentRuntime`, only owner/admin hold
    /// `deleteAgents`; the human creator always holds the acting authority.


    /// Resolve the caller against a live agent of `serverId`, or the exact
    /// refusal the upstream route answers before it touches runtime state.
    func agentLifecycleActor(
        _ authorization: String?,
        agentId: String,
        serverId: String,
        capability: AgentLifecycleCapability
    ) -> (actor: AgentLifecycleActor?, reply: HTTPReply?) {
        guard let userId = sessionUserId(authorization: authorization) else {
            return (nil, Self.json(401, "{\"error\":\"Unauthorized\"}"))
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted else {
            return (nil, Self.json(404, "{\"error\":\"Agent not found\"}"))
        }
        guard serverId.isEmpty || info.serverId == serverId else {
            return (nil, Self.json(404, "{\"error\":\"Agent not found\"}"))
        }
        guard let role = oauth.memberRole(serverId: info.serverId, userId: userId) else {
            return (nil, Self.json(403, "{\"error\":\"Not a member of this server\"}"))
        }
        let isCreator = info.creatorUserId == userId
        guard capability.granted(role: role, isCreator: isCreator) else {
            return (nil, Self.json(403, "{\"error\":\(jsonString(capability.denialMessage))}"))
        }
        return (AgentLifecycleActor(userId: userId, role: role, info: info), nil)
    }

    public func setScopeAttestationSecretForTesting(_ secret: String?) {
        lock.lock()
        scopeAttestationSecretOverride = .some(secret)
        lock.unlock()
    }

    public func setDeploymentEnvironmentForTesting(_ environment: String?) {
        lock.lock()
        deploymentEnvironmentOverride = .some(environment)
        lock.unlock()
    }

    public func setComputerAttachEnabledForTesting(_ enabled: Bool?) {
        lock.lock()
        computerAttachEnabledOverride = enabled
        lock.unlock()
    }

    func computerAttachEnabled() -> Bool {
        lock.lock()
        let override = computerAttachEnabledOverride
        lock.unlock()
        if let override { return override }
        let raw = (ProcessInfo.processInfo.environment["SLOCK_DEVICE_LOGIN_ENABLED"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw != "false"
    }

    /// `POST /internal/computer/preflight`. Read-only principal check for an
    /// attached Computer credential. The published route-auth projection is
    /// derived from the live router by the caller, so this surface describes
    /// what is actually registered instead of a parallel list.
    public func computerPreflight(authorization: String?, surface: InternalSurfaceSnapshot) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let computer = computers.first { $0.apiKey == token && $0.revokedAt == nil }
        lock.unlock()
        guard let computer, let details = oauth.serverDetailsValue(id: computer.serverId) else {
            return Self.json(401, "{\"error\":\"Invalid principal for this surface\",\"code\":\"invalid_principal\"}")
        }
        let claimed = surface.claimedPrefixes.map(jsonString).joined(separator: ",")
        let principals = surface.registeredPrincipals.map(jsonString).joined(separator: ",")
        return Self.json(200, "{\"ok\":true,\"surfaceVersion\":\(jsonString(surface.surfaceVersion)),\"claimedPrefixes\":[\(claimed)],\"registeredPrincipals\":[\(principals)],\"computerSurface\":[\(surface.computerSurfaceJSON())],\"serverId\":\(jsonString(computer.serverId)),\"serverSlug\":\(jsonString(details.slug)),\"principal\":{\"kind\":\"computer\",\"id\":\(jsonString(computer.id)),\"name\":\(jsonString(computer.name))}}")
    }

    /// `POST /internal/computer/*` for a path the surface registry does not
    /// claim: a live Computer principal is told the path is unregistered
    /// instead of receiving a routing 404.
    public func unregisteredInternalComputerSurface(authorization: String?) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let live = computers.contains { $0.apiKey == token && $0.revokedAt == nil }
        lock.unlock()
        guard live else {
            return Self.json(401, "{\"error\":\"Invalid principal for this surface\",\"code\":\"invalid_principal\"}")
        }
        return Self.json(401, "{\"error\":\"This internal surface is not registered\",\"code\":\"auth_policy_unregistered_path\"}")
    }

    /// `/internal/agent-api/*` and `/internal/agent/*` for a path the surface
    /// registry does not claim: a live agent credential is told the path is
    /// unregistered instead of receiving a routing 404, so a missing policy
    /// entry fails closed on the same envelope as `/internal/computer/*`.
    public func unregisteredInternalAgentSurface(authorization: String?) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let liveAgent = agentCredentials[token] != nil
        lock.unlock()
        guard liveAgent else {
            return Self.json(401, "{\"error\":\"Invalid principal for this surface\",\"code\":\"invalid_principal\"}")
        }
        return Self.json(401, "{\"error\":\"This internal surface is not registered\",\"code\":\"auth_policy_unregistered_path\"}")
    }

    public func agentRuntimeProviderProbe(authorization: String?, serverId: String, kind: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard kind == "antiproton" else {
            return Self.json(404, "{\"error\":\"Unknown runtime provider\"}")
        }
        let available = hostedProviderAvailable(serverId: serverId)
        return Self.json(200, "{\"kind\":\"antiproton\",\"available\":\(available)}")
    }

}
