import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Product feedback locators (`POST/GET /internal/agent-api/feedback-locators`).
///
/// The service reads the credential, channel and locator ledgers through the
/// directory's forwarding accessors. The directory only keeps the delegating
/// entry points and the credential/grant helpers shared with the rest of the
/// agent API surface.
struct FeedbackLocatorService {
    let directory: EmailLoginDirectory

    init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    // MARK: - Credential identity

    /// The credential/capability outcome without an HTTP reply, for callers
    /// that own their own error projection (the managed-MCP service).
    ///
    /// `locatorIdentity` below maps these cases back to the exact published
    /// refusals, so the feedback-locator routes keep their bytes.
    enum IdentityResolution: Sendable, Equatable {
        case success(agentId: String, serverId: String)
        case missingAuthorization
        case invalidAccessToken
        case capabilityNotAuthorized(capability: String)
        case invalidAgentCredential
    }

    func identityResolution(
        authorization: String?,
        capability: String
    ) -> IdentityResolution {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .missingAuthorization
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        directory.lock.lock()
        let credential = directory.agentCredentials[token]
        directory.lock.unlock()
        guard let credential, credential.revokedAt == nil else {
            return .invalidAccessToken
        }
        guard credential.scopes.contains(capability) else {
            return .capabilityNotAuthorized(capability: capability)
        }
        guard let agent = directory.oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return .invalidAgentCredential
        }
        return .success(agentId: credential.agentId, serverId: agent.serverId)
    }

    func locatorIdentity(
        authorization: String?,
        capability: String
    ) -> FeedbackLocatorIdentityResult {
        switch identityResolution(authorization: authorization, capability: capability) {
        case .success(let agentId, let serverId):
            return .success(agentId: agentId, serverId: serverId)
        case .missingAuthorization:
            return .refused(EmailLoginDirectory.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"))
        case .invalidAccessToken:
            return .refused(EmailLoginDirectory.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        case .capabilityNotAuthorized(let capability):
            return .refused(EmailLoginDirectory.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\(jsonString(capability))}"))
        case .invalidAgentCredential:
            return .refused(EmailLoginDirectory.json(401, "{\"error\":\"Invalid agent credential\",\"code\":\"auth_required\"}"))
        }
    }

    func failure(_ status: Int, _ reason: String) -> HTTPReply {
        EmailLoginDirectory.json(status, "{\"status\":\"failed\",\"reason_code\":\(jsonString(reason))}")
    }

    // MARK: - Locator ingest and listing

    func ingest(authorization: String?, body: String) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch locatorIdentity(authorization: authorization, capability: "send") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let envelope = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return failure(400, "invalid_payload")
        }
        guard (envelope["artifact_kind"] as? String) == "raft-feedback-locator-v0" else {
            return failure(400, "unknown_artifact_kind")
        }
        guard (envelope["event_kind"] as? String) == "feedback-locator:created" else {
            return failure(400, "unknown_event_kind")
        }
        guard let payload = envelope["payload"] as? [String: Any] else {
            return failure(400, "invalid_payload")
        }
        if EmailLoginDirectory.feedbackContainsForbiddenKey(payload) {
            return failure(400, "forbidden_field")
        }
        let route = payload["route"] as? [String: Any]
        let resolution = route?["resolution"] as? [String: Any]
        if let resolution, (resolution["status"] as? String) != "resolved",
           resolution["target"] != nil || resolution["ref"] != nil {
            return failure(400, "invalid_route_ref")
        }
        if let target = resolution?["target"] as? [String: Any] {
            guard (target["kind"] as? String) == "public_channel",
                  let ref = target["ref"] as? String,
                  ref.range(of: "^#[a-z0-9][a-z0-9_-]{0,126}$", options: [.regularExpression, .caseInsensitive]) != nil
            else {
                return failure(400, "invalid_route_ref")
            }
        }
        guard (payload["schema_version"] as? String) == "raft.feedback.locator.v0" else {
            return failure(400, "unknown_schema_version")
        }
        guard let reportId = payload["report_id"] as? String,
              ServerScope.isUUID(reportId),
              let capturedRaw = payload["captured_at"] as? String,
              let capturedAt = EmailLoginDirectory.isoDate(capturedRaw),
              let producer = payload["producer"] as? [String: Any],
              (producer["server_id"] as? String) == identity.serverId,
              (producer["agent_id"] as? String) == identity.agentId,
              let locators = payload["locators"] as? [String: Any],
              let l0 = locators["l0"] as? [String: Any],
              let runtime = l0["runtime"] as? String,
              let native = l0["native"] as? [String: Any],
              let nativeStatus = native["status"] as? String
        else {
            return failure(400, "invalid_payload")
        }
        if (resolution?["status"] as? String) == "resolved" {
            if let delivery = route?["delivery"] as? [String: Any],
               let status = delivery["status"] as? String,
               status == "accepted" || status == "failed" {
                return failure(400, "invalid_payload")
            }
            guard let ref = (resolution?["target"] as? [String: Any])?["ref"] as? String,
                  ref == "#proj-feedback"
            else {
                return failure(400, "invalid_route_ref")
            }
            let name = String(ref.dropFirst())
            directory.lock.lock()
            let exists = directory.postableChannels.values.contains {
                $0.serverId == identity.serverId && $0.kind == "channel" && $0.name == name && $0.deletedAt == nil
            }
            directory.lock.unlock()
            guard exists else {
                return failure(400, "invalid_route_ref")
            }
        }
        let nativeLookupMethod = native["lookup_method"] as? String ?? "not_attempted"
        let nativeLocatorKind = native["locator_kind"] as? String ?? "none"
        var servedExactSha256: [String] = []
        if let exacts = payload["exacts"] as? [Any] {
            for entry in exacts {
                guard let row = entry as? [String: Any],
                      (row["status"] as? String) == "retained",
                      let sha = row["sha256"] as? String
                else { continue }
                servedExactSha256.append(sha)
            }
        }
        let routeBasis = (resolution?["status"] as? String) == "resolved" ? resolution?["basis"] as? String : nil
        let routeTarget = (resolution?["status"] as? String) == "resolved"
            ? (resolution?["target"] as? [String: Any])?["ref"] as? String
            : nil
        let digest = EmailLoginDirectory.sha256(EmailLoginDirectory.feedbackStableJSON(payload))
        directory.lock.lock()
        if let existing = directory.feedbackLocatorRecords.first(where: {
            $0.serverId == identity.serverId && $0.reportId == reportId
        }) {
            let same = existing.payloadSha256 == digest
            let receipt = existing.receiptId
            directory.lock.unlock()
            if !same {
                return failure(409, "report_identity_conflict")
            }
            return EmailLoginDirectory.json(200, "{\"status\":\"accepted\",\"receipt_id\":\(jsonString(receipt)),\"report_id\":\(jsonString(reportId)),\"duplicate\":true}")
        }
        let receiptId = UUID().uuidString.lowercased()
        directory.feedbackLocatorRecords.append(FeedbackLocatorRecord(
            serverId: identity.serverId,
            producerAgentId: identity.agentId,
            reportId: reportId,
            receiptId: receiptId,
            capturedAt: capturedAt,
            runtime: runtime,
            nativeStatus: nativeStatus,
            nativeLookupMethod: nativeLookupMethod,
            nativeLocatorKind: nativeLocatorKind,
            hasServedExact: !servedExactSha256.isEmpty,
            servedExactSha256: servedExactSha256,
            routeBasis: routeBasis,
            routeTarget: routeTarget,
            payloadSha256: digest,
            createdAt: Date()
        ))
        directory.lock.unlock()
        return EmailLoginDirectory.json(200, "{\"status\":\"accepted\",\"receipt_id\":\(jsonString(receiptId)),\"report_id\":\(jsonString(reportId)),\"duplicate\":false}")
    }

    func list(
        authorization: String?,
        reportId: String?,
        runtime: String?,
        nativeStatus: String?,
        nativeLookupMethod: String?,
        servedExactSha256: String?,
        routeBasis: String?,
        limit rawLimit: String?
    ) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch locatorIdentity(authorization: authorization, capability: "read") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        let limit = min(max(Int(rawLimit ?? "") ?? 50, 1), 100)
        directory.lock.lock()
        var rows = directory.feedbackLocatorRecords
            .filter { $0.serverId == identity.serverId }
            .sorted { $0.createdAt > $1.createdAt }
        if let reportId, !reportId.isEmpty { rows = rows.filter { $0.reportId == reportId } }
        if let runtime, !runtime.isEmpty { rows = rows.filter { $0.runtime == runtime } }
        if let nativeStatus, !nativeStatus.isEmpty { rows = rows.filter { $0.nativeStatus == nativeStatus } }
        if let nativeLookupMethod, !nativeLookupMethod.isEmpty {
            rows = rows.filter { $0.nativeLookupMethod == nativeLookupMethod }
        }
        if let servedExactSha256, !servedExactSha256.isEmpty {
            rows = rows.filter { $0.servedExactSha256.contains(servedExactSha256) }
        }
        if let routeBasis, !routeBasis.isEmpty { rows = rows.filter { $0.routeBasis == routeBasis } }
        rows = Array(rows.prefix(limit))
        let locators = rows.map { row -> String in
            let shas = row.servedExactSha256.map { jsonString($0) }.joined(separator: ",")
            let basis = row.routeBasis.map(jsonString) ?? "null"
            let target = row.routeTarget.map(jsonString) ?? "null"
            return "{\"report_id\":\(jsonString(row.reportId)),\"receipt_id\":\(jsonString(row.receiptId)),\"captured_at\":\(jsonString(EmailLoginDirectory.isoString(row.capturedAt))),\"runtime\":\(jsonString(row.runtime)),\"native_status\":\(jsonString(row.nativeStatus)),\"native_lookup_method\":\(jsonString(row.nativeLookupMethod)),\"native_locator_kind\":\(jsonString(row.nativeLocatorKind)),\"has_served_exact\":\(row.hasServedExact),\"served_exact_sha256\":[\(shas)],\"route_basis\":\(basis),\"route_target\":\(target)}"
        }.joined(separator: ",")
        directory.lock.unlock()
        return EmailLoginDirectory.json(200, "{\"locators\":[\(locators)]}")
    }
}

// MARK: - Directory entry points

extension EmailLoginDirectory {
    /// Payload keys that would smuggle conversation content into a locator.
    static let feedbackLocatorForbiddenKeys: Set<String> = [
        "body", "content", "content_window", "context", "context_window", "feedback_body",
        "l3", "message_body", "path", "prompt", "raw", "raw_args", "raw_argv", "raw_error",
        "raw_value", "raw_values", "searched_paths", "searchedpaths", "session_content",
        "session_text", "stderr", "stdin", "stdout", "trajectory", "transcript", "value",
        "values", "wider_window", "window",
    ]

    func agentCapabilityDenial(_ authorization: String?, required: String) -> HTTPReply? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil else { return nil }
        if credential.scopes.contains(required) { return nil }
        return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\(jsonString(required))}")
    }

    func agentGrantDenial(agentId: String, scope: String) -> HTTPReply? {
        lock.lock()
        let grants = agentGrantSets[agentId]
        lock.unlock()
        guard let grants, !grants.contains(scope) else { return nil }
        return Self.json(403, "{\"error\":\"missing required scope\",\"requiredScope\":\(jsonString(scope)),\"reason\":\"missing_scope\"}")
    }

    func agentCredentialIdentity(authorization: String?, capability: String) -> (agentId: String, serverId: String)? {
        guard case .success(let agentId, let serverId) = feedbackLocatorIdentity(authorization: authorization, capability: capability) else {
            return nil
        }
        return (agentId, serverId)
    }

    func agentCredentialScopes(authorization: String?) -> [String]? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock(); defer { lock.unlock() }
        return agentCredentials[token].map { Array($0.scopes) }
    }

    func feedbackLocatorIdentity(
        authorization: String?,
        capability: String
    ) -> FeedbackLocatorIdentityResult {
        FeedbackLocatorService(directory: self).locatorIdentity(authorization: authorization, capability: capability)
    }

    func feedbackLocatorFailure(_ status: Int, _ reason: String) -> HTTPReply {
        FeedbackLocatorService(directory: self).failure(status, reason)
    }

    public func ingestFeedbackLocator(authorization: String?, body: String) -> HTTPReply {
        FeedbackLocatorService(directory: self).ingest(authorization: authorization, body: body)
    }

    public func listFeedbackLocators(
        authorization: String?,
        reportId: String?,
        runtime: String?,
        nativeStatus: String?,
        nativeLookupMethod: String?,
        servedExactSha256: String?,
        routeBasis: String?,
        limit rawLimit: String?
    ) -> HTTPReply {
        FeedbackLocatorService(directory: self).list(
            authorization: authorization,
            reportId: reportId,
            runtime: runtime,
            nativeStatus: nativeStatus,
            nativeLookupMethod: nativeLookupMethod,
            servedExactSha256: servedExactSha256,
            routeBasis: routeBasis,
            limit: rawLimit
        )
    }
}
