import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Server profile, server order, translation settings and shared-artifact pages.
///
/// These handlers were lifted from the first contiguous half of
/// `EmailLogin+ComputersUsage2.swift`. They stay on `EmailLoginDirectory`
/// because the directory owns the lock and the server/channel ledgers;
/// `ServerProfileAndOrderService` is the named, `Sendable` handle for the
/// domain.
public struct ServerProfileAndOrderService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {


    /// `GET /share/:id`. The public page carries the canonical OG metadata for
    /// the configured share host and image host.
    public func shareArtifactPage(id: String, serverBase: String, shareBase: String, cdnBase: String?) -> HTTPReply? {
        guard id.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return nil
        }
        lock.lock()
        let artifact = shareArtifacts[id.lowercased()]
        lock.unlock()
        guard let artifact else { return nil }
        let shareURL = Self.shareURL(id: id, shareBase: shareBase)
        let imageURL = Self.shareImageURL(id: id, serverId: artifact.serverId, serverBase: serverBase, cdnBase: cdnBase)
        let title = "Slock conversation screenshot"
        let description = "A conversation screenshot shared from Slock."
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(Self.escapeHTML(title))</title>
          <meta name="robots" content="noindex, nofollow">
          <meta property="og:type" content="article">
          <meta property="og:title" content="\(Self.escapeHTML(title))">
          <meta property="og:description" content="\(Self.escapeHTML(description))">
          <meta property="og:url" content="\(Self.escapeHTML(shareURL))">
          <meta property="og:image" content="\(Self.escapeHTML(imageURL))">
          <meta property="og:image:secure_url" content="\(Self.escapeHTML(imageURL))">
          <meta property="og:image:type" content="image/png">
          <meta property="og:image:width" content="\(artifact.width)">
          <meta property="og:image:height" content="\(artifact.height)">
          <meta name="twitter:card" content="summary_large_image">
          <meta name="twitter:title" content="\(Self.escapeHTML(title))">
          <meta name="twitter:description" content="\(Self.escapeHTML(description))">
          <meta name="twitter:image" content="\(Self.escapeHTML(imageURL))">
          <meta name="twitter:image:alt" content="\(Self.escapeHTML(title))">
          <style>
            body { margin: 0; font-family: ui-sans-serif, system-ui, sans-serif; background: #fffdf4; color: #111; }
            main { min-height: 100vh; display: grid; place-items: center; padding: 24px; box-sizing: border-box; }
            .share-card { width: min(100%, 960px); margin-inline: auto; }
            img { display: block; width: 100%; height: auto; border: 2px solid #111; box-shadow: 4px 4px 0 #111; background: #fff; box-sizing: border-box; }
            p { font-size: 13px; color: rgba(0,0,0,.6); margin-top: 16px; }
          </style>
        </head>
        <body>
          <main>
            <div class="share-card">
              <img src="\(Self.escapeHTML(imageURL))" alt="\(Self.escapeHTML(title))">
              <p>Shared from Slock.</p>
            </div>
          </main>
        </body>
        </html>
        """
        return HTTPReply(
            status: 200,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "public, max-age=300",
                "X-Robots-Tag": "noindex, nofollow",
                "Content-Length": String(Data(html.utf8).count),
            ],
            body: html
        )
    }

    /// `GET /share/:id.png`. Serves the uploaded bytes with the non-expiring
    /// immutable cache the public card depends on.
    public func shareArtifactImage(id: String) -> (bytes: Data, width: Int, height: Int)? {
        guard id.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return nil
        }
        lock.lock()
        let artifact = shareArtifacts[id.lowercased()]
        lock.unlock()
        guard let artifact else { return nil }
        return (artifact.bytes, artifact.width, artifact.height)
    }

    func humanUnreadCount(channelId: String, userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let rows = humanMessageRows.filter { $0.channelId == channelId }
        let cursor = oauth.channelUnreadInfo(channelId: channelId, userId: userId).maxReadSeq
        return rows.filter { $0.seq > cursor && $0.senderId != userId }.count
    }

    public func serversUnreadSummary(authorization: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let entries = oauth.serverIdsForMember(userId: userId).map { serverId -> String in
            let joined = oauth.channelsForServer(serverId: serverId, userId: userId).filter {
                $0.joined && ($0.type == "channel" || $0.type == "")
            }
            let total = joined.reduce(0) { sum, channel in
                sum + oauth.channelUnreadInfo(channelId: channel.id, userId: userId).unreadCount
            }
            let muted = oauth.isServerPushMuted(serverId: serverId, userId: userId)
            return "{\"serverId\":\(jsonString(serverId)),\"unreadCount\":\(total),\"serverPushMuted\":\(muted),\"activityUnreadCount\":\(total)}"
        }.joined(separator: ",")
        return Self.privateJSON("[\(entries)]")
    }

    public func observeTimezone(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              Set(object.keys) == ["timezone"],
              let raw = object["timezone"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid timezone observation\"}")
        }
        let timezone = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !timezone.isEmpty, timezone.count <= 128,
              timezone == "UTC" || timezone.contains("/"),
              let zone = TimeZone(identifier: timezone)
        else {
            return Self.json(400, "{\"error\":\"Invalid timezone observation\"}")
        }
        let canonicalTimezone = Self.timezoneAliases[timezone] ?? zone.identifier
        lock.lock()
        var observation = timezoneObservations[userId]
        let now = Date()
        if observation == nil {
            observation = TimezoneObservation(firstTimezone: canonicalTimezone, firstAt: now, lastTimezone: canonicalTimezone, lastAt: now)
        } else if let existing = observation {
            observation = TimezoneObservation(
                firstTimezone: existing.firstTimezone,
                firstAt: existing.firstAt,
                lastTimezone: canonicalTimezone,
                lastAt: now
            )
        }
        timezoneObservations[userId] = observation
        lock.unlock()
        guard let stored = observation else {
            return Self.json(500, "{\"error\":\"Timezone observation not stored\"}")
        }
        return Self.json(200, Self.timezoneJSON(stored))
    }

    public func timezoneObservation(userId: String) -> TimezoneObservation? {
        lock.lock()
        defer { lock.unlock() }
        return timezoneObservations[userId]
    }


    public func authenticatedUserId(authorization: String?) -> String? {
        sessionUserId(authorization: authorization)
    }

    public func machineIdForCredential(authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        defer { lock.unlock() }
        if let machine = machines.first(where: { $0.apiKey == token }) { return machine.id }
        if let computer = computers.first(where: { $0.apiKey == token && $0.revokedAt == nil }) {
            return computer.machineId
        }
        return nil
    }

    func canMachineServeAgent(machineId: String, agent: OAuthLedger.AgentRuntimeInfo) -> Bool {
        lock.lock()
        let bound = agentMachineIds[agent.id]
        let machineServer = machines.first { $0.id == machineId }?.serverId
        lock.unlock()
        guard machineServer == agent.serverId else { return false }
        if let bound { return bound == machineId }
        return true
    }

    public func machineScopeAttestation(authorization: String?, body: String) -> HTTPReply {
        guard let machineId = machineIdForCredential(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        lock.lock()
        let secretOverride = scopeAttestationSecretOverride
        let deploymentOverride = deploymentEnvironmentOverride
        lock.unlock()
        let secretValue: String?
        if let secretOverride { secretValue = secretOverride } else {
            secretValue = ProcessInfo.processInfo.environment["SCOPE_ATTESTATION_SECRET"]
        }
        guard let secret = secretValue, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.json(503, "{\"error\":\"Scope attestation signing is not configured\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let scope = object["scope"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid attestation request\"}")
        }
        if object["audience"] != nil {
            return Self.json(400, "{\"error\":\"audience is derived from scope\"}")
        }
        if object["resource"] != nil {
            return Self.json(400, "{\"error\":\"resource is derived from scope\"}")
        }
        let supportedScopes: [String: (audience: String, suffix: String)] = [
            "feedback-report:create": ("feedback-worker", "feedback-reports"),
            "daemon-trace-bundle:create": ("trace-ingest-worker", "trace-bundles"),
            "machine_log_tail:create": ("trace-ingest-worker", "trace-bundles"),
            "machine_evidence:create": ("trace-ingest-worker", "trace-bundles"),
        ]
        guard let scopeContract = supportedScopes[scope] else {
            return Self.json(400, "{\"error\":\"Unsupported scope: \(scope)\"}")
        }
        lock.lock()
        let machine = machines.first { $0.id == machineId }
        let serverId = machine?.serverId ?? ""
        let serverSlug = oauth.serverProfile(id: serverId)?.slug ?? ""
        lock.unlock()
        guard !serverId.isEmpty else {
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        let resource = "servers/\(serverId)/machines/\(machineId)/\(scopeContract.suffix)"
        var metadata: [String: Any] = [:]
        let rawMetadata = object["metadata"] as? [String: Any] ?? [:]
        if scope == "daemon-trace-bundle:create" || scope == "machine_log_tail:create" || scope == "machine_evidence:create" {
            guard let bundleId = Self.attestationString(rawMetadata["bundleId"]), !bundleId.isEmpty, bundleId.count <= 128,
                  let bundleSha256 = Self.attestationString(rawMetadata["bundleSha256"]), bundleSha256.count == 64,
                  let bundleSizeBytes = Self.attestationInt(rawMetadata["bundleSizeBytes"])
            else {
                return Self.json(400, "{\"error\":\"Invalid attestation request\"}")
            }
            metadata["bundleId"] = bundleId
            metadata["bundleSha256"] = bundleSha256
            metadata["bundleSizeBytes"] = bundleSizeBytes
            if let contentType = Self.attestationString(rawMetadata["bundleContentType"]), contentType.count > 128 {
                return Self.json(400, "{\"error\":\"bundleContentType is too long\"}")
            }
            if let encoding = Self.attestationString(rawMetadata["bundleContentEncoding"]), encoding.count > 64 {
                return Self.json(400, "{\"error\":\"bundleContentEncoding is too long\"}")
            }
            if let reportId = rawMetadata["feedbackReportId"] {
                guard let text = reportId as? String, ServerScope.isUUID(text) else {
                    return Self.json(400, "{\"error\":\"feedbackReportId must be a canonical UUID\"}")
                }
                metadata["feedbackReportId"] = text
            }
            if let agentId = rawMetadata["agentId"] {
                guard let text = agentId as? String, ServerScope.isUUID(text) else {
                    return Self.json(400, "{\"error\":\"agentId must be a canonical UUID\"}")
                }
                metadata["agentId"] = text
            }
            let requestedKind = Self.attestationString(rawMetadata["feedbackAttachmentKind"])
            if let requestedKind, ["session_transcript", "transcript_outcome", "machine_log_tail", "machine_evidence"].contains(requestedKind) {
                metadata["feedbackAttachmentKind"] = requestedKind
            }
            let kind = metadata["feedbackAttachmentKind"] as? String ?? "session_transcript"
            let envValue: String?
            if let deploymentOverride { envValue = deploymentOverride } else {
                envValue = ProcessInfo.processInfo.environment["DEPLOYMENT_ENV"]
            }
            let serverEnv = (envValue ?? "production").lowercased()
            let producerEnv = Self.attestationString(rawMetadata["deploymentEnvironment"])
            if let producerEnv {
                let allowed = ["dev", "development", "staging", "production"]
                guard allowed.contains(producerEnv) else {
                    return Self.json(400, "{\"error\":\"deploymentEnvironment \(producerEnv) is not in the allowed producer set\"}")
                }
                if serverEnv != producerEnv, !(serverEnv == "staging" && (producerEnv == "dev" || producerEnv == "development")) {
                    let deploymentMessage = "deploymentEnvironment \(producerEnv) is inconsistent with server deployment \"\(serverEnv)\""
                    return Self.json(400, "{\"error\":\(jsonString(deploymentMessage))}")
                }
                metadata["deploymentEnvironment"] = producerEnv
            } else {
                metadata["deploymentEnvironment"] = serverEnv
            }
            if kind == "machine_log_tail" {
                for key in ["feedbackMachineLogTailLineCount", "feedbackMachineLogTailSourceLineCount",
                            "feedbackMachineLogTailLinesOutsideWindow", "feedbackMachineLogTailUndatedLines"] {
                    if let value = Self.attestationInt(rawMetadata[key]), value <= 10_000_000 {
                        metadata[key] = value
                    }
                }
                for key in ["feedbackMachineLogTailTruncated", "feedbackMachineLogTailIncludesOtherAgents"] {
                    if let value = rawMetadata[key] as? String, value == "true" || value == "false" {
                        metadata[key] = value
                    }
                }
            }
            if kind == "machine_evidence" {
                guard let agentId = metadata["agentId"] as? String, let reportId = metadata["feedbackReportId"] as? String else {
                    return Self.json(400, "{\"error\":\"Invalid attestation request\"}")
                }
                lock.lock()
                let agent = oauth.agentRuntimeInfo(id: agentId)
                let boundMachine = agentMachineIds[agentId]
                lock.unlock()
                guard agent?.serverId == serverId, boundMachine == machineId else {
                    return Self.json(403, "{\"error\":\"Agent does not belong to this machine\",\"code\":\"agent_not_on_machine\"}")
                }
                let maxBytes = 256 * 1024
                guard bundleSizeBytes <= maxBytes else {
                    return Self.json(400, "{\"error\":\"Evidence bundle is too large\",\"code\":\"evidence_bundle_too_large\"}")
                }
                metadata["feedbackReportId"] = reportId
                metadata["feedbackAttachmentKind"] = kind
                metadata["objectKey"] = "feedback-machine-evidence/\(serverId)/\(machineId)/\(UUID().uuidString.lowercased()).json.gz"
                metadata["bundleContentType"] = "application/json"
                metadata["bundleContentEncoding"] = "gzip"
                metadata["maxBytes"] = maxBytes
                metadata.removeValue(forKey: "machineId")
                metadata.removeValue(forKey: "serverId")
            } else if kind == "transcript_outcome" {
                guard let agentId = metadata["agentId"] as? String,
                      metadata["feedbackReportId"] != nil,
                      let requestId = Self.attestationString(rawMetadata["feedbackTranscriptRequestId"]),
                      requestId.wholeMatch(of: /^[^\s]{1,128}$/) != nil
                else {
                    return Self.json(400, "{\"error\":\"Invalid attestation request\"}")
                }
                lock.lock()
                let agent = oauth.agentRuntimeInfo(id: agentId)
                let boundMachine = agentMachineIds[agentId]
                lock.unlock()
                guard agent?.serverId == serverId, boundMachine == machineId else {
                    return Self.json(403, "{\"error\":\"Agent does not belong to this machine\",\"code\":\"agent_not_on_machine\"}")
                }
                let maxBytes = 2048
                guard bundleSizeBytes <= maxBytes else {
                    return Self.json(400, "{\"error\":\"Outcome bundle is too large\",\"code\":\"outcome_bundle_too_large\"}")
                }
                metadata["feedbackTranscriptRequestId"] = requestId
                metadata["objectKey"] = "feedback-transcript-outcomes/\(serverId)/\(machineId)/\(UUID().uuidString.lowercased()).json.gz"
                metadata["bundleContentType"] = "application/json"
                metadata["bundleContentEncoding"] = "gzip"
                metadata["maxBytes"] = maxBytes
                metadata.removeValue(forKey: "feedbackTranscriptContent")
            } else {
                let contentType = Self.attestationString(rawMetadata["bundleContentType"]) ?? "application/x-ndjson"
                let encoding = Self.attestationString(rawMetadata["bundleContentEncoding"]) ?? "gzip"
                metadata["bundleContentType"] = contentType
                metadata["bundleContentEncoding"] = encoding
                metadata["maxBytes"] = 50 * 1024 * 1024
                metadata["objectKey"] = "trace-bundles/\(serverId)/\(machineId)/\(UUID().uuidString.lowercased()).jsonl.gz"
            }
            let timeKeys = ["feedbackReportGeneratedAt", "feedbackReportWindowStartAt",
                            "feedbackTranscriptFirstEventAt", "feedbackTranscriptLastEventAt"]
            for key in timeKeys {
                if let value = Self.attestationString(rawMetadata[key]), !value.isEmpty, value.count <= 64 {
                    metadata[key] = value
                }
            }
            if let source = Self.attestationString(rawMetadata["feedbackReportTimeSource"]),
               ["web_report_bundle", "computer_clock", "unknown"].contains(source) {
                metadata["feedbackReportTimeSource"] = source
            }
            if let coverage = Self.attestationString(rawMetadata["feedbackTranscriptWindowCoverage"]),
               ["timestamps_available", "timestamps_unavailable", "covered"].contains(coverage) {
                metadata["feedbackTranscriptWindowCoverage"] = coverage
            }
            if let direction = Self.attestationString(rawMetadata["feedbackTranscriptTruncationDirection"]),
               ["window", "size", "tail"].contains(direction) {
                metadata["feedbackTranscriptTruncationDirection"] = direction
            }
            if let truncated = rawMetadata["feedbackTranscriptTruncated"] {
                if let bool = truncated as? Bool { metadata["feedbackTranscriptTruncated"] = bool ? "true" : "false" }
                else if let text = truncated as? String, text == "true" || text == "false" {
                    metadata["feedbackTranscriptTruncated"] = text
                }
            }
            if let tolerance = Self.attestationInt(rawMetadata["feedbackTranscriptWindowToleranceMs"]),
               tolerance <= 24 * 60 * 60 * 1000 {
                metadata["feedbackTranscriptWindowToleranceMs"] = tolerance
            }
            if kind != "transcript_outcome",
               let content = Self.attestationString(rawMetadata["feedbackTranscriptContent"]),
               ["native_session_file", "native_state_file"].contains(content) {
                metadata["feedbackTranscriptContent"] = content
            }
            for key in ["feedbackTranscriptSourceBytes", "feedbackTranscriptBytes"] {
                if let value = Self.attestationInt(rawMetadata[key]) { metadata[key] = value }
            }
            if let requestId = Self.attestationString(rawMetadata["feedbackTranscriptRequestId"]),
               requestId.wholeMatch(of: /^[^\s]{1,128}$/) != nil {
                metadata["feedbackTranscriptRequestId"] = requestId
            }
            metadata.removeValue(forKey: "machineId")
            metadata.removeValue(forKey: "serverId")
        }
        let expires = Int(Date().timeIntervalSince1970) + 120
        var claims: [String: Any] = [
            "sub": "machine:\(machineId)", "actorType": "machine", "machineId": machineId,
            "serverId": serverId, "serverSlug": serverSlug, "scope": scope,
            "aud": scopeContract.audience, "resource": resource,
            "jti": UUID().uuidString.lowercased(), "nonce": UUID().uuidString.lowercased(),
            "exp": expires,
        ]
        if !metadata.isEmpty { claims["metadata"] = metadata }
        let claimsJSON = Self.serializeJSON(claims)
        let headerJSON = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
        func b64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let signingInput = "\(b64(Data(headerJSON.utf8))).\(b64(Data(claimsJSON.utf8)))"
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: SymmetricKey(data: Data(secret.utf8))))
        let attestation = "\(signingInput).\(b64(mac))"
        let metadataJSON = metadata.isEmpty ? "null" : claimsJSON
        _ = metadataJSON
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(expires)))
        let metadataResponse = metadata.isEmpty ? "null" : Self.serializeJSON(metadata)
        return Self.json(200, "{\"attestation\":\(jsonString(attestation)),\"scope\":\(jsonString(scope)),\"audience\":\(jsonString(scopeContract.audience)),\"resource\":\(jsonString(resource)),\"expiresAt\":\(jsonString(expiresAt)),\"metadata\":\(metadataResponse)}")
    }

    public func serverScopeAttestation(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let scope = object["scope"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid scope attestation request\"}")
        }
        let audience: String
        let resource: String
        switch scope {
        case "web-trace-batch:create":
            audience = "trace-ingest-worker"
            resource = "servers/\(serverId)/web-traces"
        case "feedback-report:create":
            guard role == "owner" || role == "admin" else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            audience = "feedback-worker"
            resource = "servers/\(serverId)/feedback-reports"
        default:
            return Self.json(400, "{\"error\":\"Unknown scope\"}")
        }
        let expiresAt = Date().addingTimeInterval(300)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header = ["alg": "HS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "scope": scope,
            "actorType": "user",
            "sub": userId,
            "serverId": serverId,
            "aud": audience,
            "resource": resource,
            "exp": Int(expiresAt.timeIntervalSince1970),
        ]
        let secret = ProcessInfo.processInfo.environment["SCOPE_ATTESTATION_SECRET"] ?? "scope-attestation-default-secret"
        let token = Self.signHS256(header: header, claims: claims, secret: secret)
        return Self.json(200, "{\"attestation\":\(jsonString(token)),\"scope\":\(jsonString(scope)),\"audience\":\(jsonString(audience)),\"resource\":\(jsonString(resource)),\"expiresAt\":\(jsonString(formatter.string(from: expiresAt)))}")
    }


    public func putServerAgreement(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can manage the pre-join agreement\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["enabled"] as? Bool,
              let title = object["title"] as? String,
              let bodyMarkdown = object["bodyMarkdown"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid agreement request\"}")
        }
        guard bodyMarkdown.count <= 5000 else {
            return Self.json(400, "{\"error\":\"Agreement body must be 5000 characters or fewer\"}")
        }
        let agreement: OAuthLedger.ServerAgreementInfo?
        if enabled {
            agreement = oauth.putServerAgreement(serverId: serverId, title: title, bodyMarkdown: bodyMarkdown)
        } else {
            agreement = nil
        }
        let json: String
        if let agreement {
            json = Self.agreementJSON(agreement)
        } else {
            json = "null"
        }
        return Self.json(200, "{\"agreement\":\(json)}")
    }

    public func getServerAgreement(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if let agreement = oauth.activeServerAgreement(serverId: serverId) {
            return Self.json(200, "{\"agreement\":\(Self.agreementJSON(agreement))}")
        }
        return Self.json(200, "{\"agreement\":null}")
    }


    func sanitizedServerOrder(userId: String, requested: [String]?) -> [String] {
        let memberIds = Set(oauth.serverIdsForMember(userId: userId))
        let stored = serverSwitcherOrders[userId]?.ids ?? []
        let base = requested ?? stored
        var seen = Set<String>()
        var ordered: [String] = []
        for id in base where memberIds.contains(id) && !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        for id in memberIds.sorted() where !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    public func seedServerSwitcherOrder(userId: String, ids: [String], version: Int) {
        lock.lock()
        serverSwitcherOrders[userId] = (ids, version)
        lock.unlock()
    }

    public func activityContractRejection() -> HTTPReply {
        HTTPReply(
            status: 400,
            headers: [
                "Content-Type": AppFallback.jsonContentType,
                "X-Raft-Contract": "raft.activity-sync;revision=2",
                "Access-Control-Expose-Headers": "X-Raft-Contract",
                "Content-Length": "26",
            ],
            body: "{\"error\":\"invalid contract\"}"
        )
    }

    public func serverOrder(authorization: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        lock.lock()
        let ordered = sanitizedServerOrder(userId: userId, requested: nil)
        let version = serverSwitcherOrders[userId]?.version ?? 0
        lock.unlock()
        let ids = ordered.map { jsonString($0) }.joined(separator: ",")
        return Self.json(200, "{\"serverOrder\":[\("\(ids)")],\"serverOrderVersion\":\(version)}")
    }

    public func patchServerOrder(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let requested = object["serverOrder"] as? [String]
        else {
            return Self.json(400, "{\"error\":\"Invalid server order\"}")
        }
        lock.lock()
        let current = serverSwitcherOrders[userId]?.ids ?? sanitizedServerOrder(userId: userId, requested: nil)
        let ordered = sanitizedServerOrder(userId: userId, requested: requested)
        var version = serverSwitcherOrders[userId]?.version ?? 0
        if ordered != current {
            version += 1
        }
        serverSwitcherOrders[userId] = (ordered, version)
        lock.unlock()
        let ids = ordered.map { jsonString($0) }.joined(separator: ",")
        return Self.json(200, "{\"serverOrder\":[\("\(ids)")],\"serverOrderVersion\":\(version)}")
    }

    public func orderedServerList(authorization: String?) -> HTTPReply? {
        guard let userId = sessionUserId(authorization: authorization) else { return nil }
        let memberIds = oauth.serverIdsForMember(userId: userId)
        guard !memberIds.isEmpty else { return nil }
        let ordered = sanitizedServerOrder(userId: userId, requested: nil)
        lock.lock()
        let version = serverSwitcherOrders[userId]?.version ?? 0
        lock.unlock()
        let rows = ordered.compactMap { serverId -> String? in
            guard let details = oauth.serverDetailsValue(id: serverId) else { return nil }
            let role = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
            return "{\"id\":\(jsonString(serverId)),\"slug\":\(jsonString(details.slug)),\"role\":\(jsonString(role)),\"serverOrderVersion\":\(version),\"publicPageLive\":false}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func enableComposerResourceReferences(serverId: String, enabled: Bool = true) {
        lock.lock()
        if enabled {
            composerResourceServers.insert(serverId)
        } else {
            composerResourceServers.remove(serverId)
        }
        lock.unlock()
    }

    public func serverApps(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let enabled = composerResourceServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let apps: [(String, String)] = [
            ("system.cleaner", "Memory Cleaner"),
            ("system.reminder", "Reminder"),
        ]
        let rows = apps.map { app in
            "{\"appId\":\(jsonString(app.0)),\"displayName\":\(jsonString(app.1))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"apps\":[\("\(rows)")]}")
    }

    func translationProviderName() -> String {
        lock.lock(); let override = translationProviderOverride; lock.unlock()
        return override ?? (ProcessInfo.processInfo.environment["TRANSLATION_PROVIDER"] ?? "")
    }

    func translationProviderAvailableInstance() -> Bool {
        lock.lock()
        let hasOverride = translationProviderOverride != nil
        lock.unlock()
        if hasOverride { return true }
        let environment = ProcessInfo.processInfo.environment
        switch translationProviderName() {
        case "fake":
            return true
        case "volcengine":
            let id = environment["TRANSLATION_VOLCENGINE_ACCESS_KEY_ID"] ?? ""
            let secret = environment["TRANSLATION_VOLCENGINE_SECRET_ACCESS_KEY"] ?? ""
            return !id.isEmpty && !secret.isEmpty
        case "google":
            let project = environment["TRANSLATION_GOOGLE_PROJECT_ID"] ?? ""
            let token = environment["TRANSLATION_GOOGLE_ACCESS_TOKEN"] ?? ""
            return !project.isEmpty && !token.isEmpty
        case "openai-compatible":
            let apiKey = environment["TRANSLATION_OPENAI_COMPATIBLE_API_KEY"] ?? ""
            let model = environment["TRANSLATION_OPENAI_COMPATIBLE_MODEL"] ?? ""
            return !apiKey.isEmpty && !model.isEmpty
        default:
            return false
        }
    }

    public func batchTranslateMessages(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard oauth.serverProfile(id: serverId)?.translationEnabled == true else {
            return Self.json(403, "{\"error\":\"Translation is disabled for this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let targetLanguage = object["targetLanguage"] as? String,
              let target = PublicTranslations.normalizeLanguage(targetLanguage),
              let mode = object["mode"] as? String, mode == "auto" || mode == "manual",
              let rawIds = object["messageIds"] as? [Any]
        else {
            return Self.json(400, "{\"error\":\"Invalid translation request\"}")
        }
        let ids = rawIds.compactMap { $0 as? String }
        guard ids.count <= 200 else {
            return Self.json(400, "{\"error\":\"Invalid translation request\"}")
        }
        let provider = translationProviderName()
        guard translationProviderAvailableInstance() else {
            return Self.json(409, "{\"error\":\"Translation provider is not configured\"}")
        }
        if provider == "openai-compatible", oauth.serverProfile(id: serverId)?.plan != "pro" {
            return Self.json(403, "{\"error\":\"LLM translation is not available for this server\"}")
        }
        let providerVersion = provider == "fake" ? "fake@v0+fake-v0" : "\(provider)@v0"
        var results: [String] = []
        for id in ids {
            guard let message = oauth.messageTranslationMetadata(id: id) else {
                results.append("{\"messageId\":\(jsonString(id)),\"status\":\"not_found\",\"targetLanguage\":\(jsonString(target))}")
                continue
            }
            lock.lock()
            let jointLocal = jointProjections.first {
                $0.canonicalChannelId == message.channelId
                    && $0.serverId == serverId
                    && $0.status == "active"
            }?.localChannelId
            lock.unlock()
            let resolvedChannelId: String? = {
                if let channel = oauth.channelInfo(id: message.channelId), channel.serverId == serverId {
                    return message.channelId
                }
                return jointLocal
            }()
            guard let resolvedChannelId,
                  let channel = oauth.channelInfo(id: resolvedChannelId),
                  channel.serverId == serverId,
                  oauth.channelType(id: resolvedChannelId) == "channel"
                      || oauth.isChannelParticipant(channelId: resolvedChannelId, userId: userId)
            else {
                results.append("{\"messageId\":\(jsonString(id)),\"status\":\"not_found\",\"targetLanguage\":\(jsonString(target))}")
                continue
            }
            let source = Self.detectTranslationLanguage(message.content)
            var skipReason: String?
            if message.senderId == userId, mode == "auto" {
                skipReason = "own_message"
            } else if message.messageType == "system" || message.senderId == "system" {
                skipReason = "system_message"
            } else if Self.translationCodeOrLinkOnly(message.content) {
                skipReason = "code_or_link_only"
            } else if source.confidence < 50 {
                skipReason = "low_confidence"
            } else if source.language == target {
                skipReason = "same_language"
            }
            if let skipReason {
                if skipReason == "same_language" {
                    messageTranslationLedger[id] = (status: "skipped", providerBilledChars: 0, targetLanguage: target, translatedContent: "")
                }
                results.append("{\"messageId\":\(jsonString(id)),\"status\":\"skipped\",\"skipReason\":\(jsonString(skipReason)),\"sourceLanguage\":\(jsonString(source.language)),\"targetLanguage\":\(jsonString(target))}")
                continue
            }
            let translated = provider == "fake" ? "[\(target)] \(message.content)" : "[\(target)] \(message.content)"
            let hash = Self.sha256Hex(Data(message.content.utf8))
            lock.lock()
            messageTranslationLedger[id] = (status: "translated", providerBilledChars: message.content.count, targetLanguage: target, translatedContent: translated)
            lock.unlock()
            results.append("{\"messageId\":\(jsonString(id)),\"status\":\"translated\",\"contentHash\":\(jsonString(hash)),\"sourceLanguage\":\(jsonString(source.language)),\"sourceConfidence\":\(source.confidence),\"targetLanguage\":\(jsonString(target)),\"translatedContent\":\(jsonString(translated)),\"provider\":\(jsonString(provider)),\"providerVersion\":\(jsonString(providerVersion)),\"placeholderPolicyVersion\":\"placeholder-v0\"}")
        }
        return Self.json(200, "{\"results\":[\("\(results.joined(separator: ","))")]}")
    }




    public func serverTranslationSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let enabled = oauth.serverProfile(id: serverId)?.translationEnabled ?? false
        let canManage = role == "owner" || role == "admin"
        return Self.json(200, "{\"translationEnabled\":\(enabled),\"translationAvailable\":\(translationProviderAvailableInstance()),\"canManageTranslation\":\(canManage)}")
    }

    public func patchServerTranslationSettings(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can update translation settings\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["translationEnabled"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"translationEnabled must be a boolean\"}")
        }
        oauth.setServerTranslationEnabled(id: serverId, enabled: enabled)
        return Self.json(200, "{\"translationEnabled\":\(enabled),\"translationAvailable\":\(translationProviderAvailableInstance()),\"canManageTranslation\":true}")
    }

    public func patchServerProfile(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let profile = oauth.serverProfile(id: serverId)
        else {
            return Self.json(400, "{\"error\":\"Invalid server update\"}")
        }
        var name = profile.name
        if let rawName = object["name"] {
            guard let text = rawName as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.json(400, "{\"error\":\"Server name is required\"}")
            }
            name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var hidden: Bool?
        if let rawHidden = object["hideHumansFromMembers"] {
            guard let value = rawHidden as? Bool else {
                return Self.json(400, "{\"error\":\"hideHumansFromMembers must be a boolean\"}")
            }
            hidden = value
        }
        oauth.updateServer(id: serverId, name: name, avatarUrl: profile.avatarUrl)
        if let hidden {
            lock.lock()
            hideHumansFromMembers[serverId] = hidden
            lock.unlock()
        }
        let hiddenValue: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return hideHumansFromMembers[serverId] == true
        }()
        let avatar = profile.avatarUrl.map { jsonString($0) } ?? "null"
        return Self.json(200, "{\"id\":\(jsonString(serverId)),\"name\":\(jsonString(name)),\"slug\":\(jsonString(profile.slug)),\"avatarUrl\":\(avatar),\"hideHumansFromMembers\":\(hiddenValue)}")
    }

    public func memberProfile(authorization: String?, serverId: String, memberId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let targetRole = oauth.memberRole(serverId: serverId, userId: memberId)
        if targetRole == nil {
            lock.lock()
            let removed = removedServerMembers.contains("\(serverId)\n\(memberId)")
            let account = accounts.values.first { $0.id == memberId }
            lock.unlock()
            let canSee = role == "owner" || role == "admin" || memberId == userId
            guard removed, canSee, let account else {
                return Self.json(404, "{\"error\":\"User not found\"}")
            }
            let email = canSee ? jsonString(account.email) : "null"
            return Self.json(200, "{\"userId\":\(jsonString(memberId)),\"name\":\(jsonString(account.name)),\"displayName\":\(jsonString(account.name)),\"email\":\(email),\"avatarUrl\":\(account.avatarUrl.map { jsonString($0) } ?? "null"),\"membershipStatus\":\"removed\"}")
        }
        lock.lock()
        let hiddenDirectory = hideHumansFromMembers[serverId] == true
        let targetAccount = accounts.values.first { $0.id == memberId }
        lock.unlock()
        let isAdmin = role == "owner" || role == "admin"
        var contextual = false
        if hiddenDirectory, !isAdmin, memberId != userId {
            contextual = oauth.channelsForServer(serverId: serverId, userId: userId)
                .contains { channel in
                    channel.type == "channel"
                        && oauth.channelArchivedAt(id: channel.id) == nil
                        && oauth.isChannelParticipant(channelId: channel.id, userId: userId)
                        && oauth.isChannelParticipant(channelId: channel.id, userId: memberId)
                }
            guard contextual else {
                return Self.json(404, "{\"error\":\"User not found\"}")
            }
        }
        let email: String
        if isAdmin || memberId == userId {
            email = targetAccount.map { jsonString($0.email) } ?? "null"
        } else {
            email = "null"
        }
        let name = jsonString(targetAccount?.name ?? "")
        let avatar = targetAccount?.avatarUrl.map { jsonString($0) } ?? "null"
        let createdAgents = oauth.serverAgents(serverId: serverId)
            .filter { !$0.deleted && $0.creatorUserId == memberId }
            .map { agent in
                "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName))}"
            }
            .joined(separator: ",")
        return Self.json(200, "{\"userId\":\(jsonString(memberId)),\"name\":\(name),\"displayName\":\(name),\"email\":\(email),\"avatarUrl\":\(avatar),\"createdAgents\":[\(createdAgents)]}")
    }

    public func serverMembersList(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let canSeeAllEmails = role == "owner" || role == "admin"
        lock.lock()
        let hiddenDirectory = hideHumansFromMembers[serverId] == true
        lock.unlock()
        var members = oauth.memberIdsWithRoles(serverId: serverId)
        if hiddenDirectory, role != "owner", role != "admin" {
            members = members.filter { $0.id == userId }
        }
        let rows = members.map { member -> String in
            lock.lock()
            let account = accounts.values.first { $0.id == member.id }
            lock.unlock()
            let email: String
            if canSeeAllEmails || member.id == userId {
                email = account.map { jsonString($0.email) } ?? "null"
            } else {
                email = "null"
            }
            let name = jsonString(account?.name ?? "")
            let displayName = jsonString(account?.name ?? "")
            let avatar = account?.avatarUrl.map { jsonString($0) } ?? "null"
            return "{\"userId\":\(jsonString(member.id)),\"role\":\(jsonString(member.role)),\"name\":\(name),\"displayName\":\(displayName),\"email\":\(email),\"avatarUrl\":\(avatar)}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func serverMemberGraph(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let hiddenDirectory = hideHumansFromMembers[serverId] == true
        lock.unlock()
        if hiddenDirectory, role != "owner", role != "admin" {
            return Self.json(403, "{\"error\":\"Member graph is not available\"}")
        }
        let memberIds = oauth.memberIds(serverId: serverId)
        let agentIds = oauth.activeAgentIds(serverId: serverId)
        let allChannelId = oauth.allChannelId(serverId: serverId)
        var channels: [(id: String, name: String, humans: [String], agents: [String])] = []
        if let allChannelId {
            channels.append((allChannelId, "all", memberIds, agentIds))
        }
        for channel in oauth.channelsForServer(serverId: serverId, userId: userId) {
            guard channel.type == "channel", channel.name != "all",
                  oauth.channelArchivedAt(id: channel.id) == nil
            else { continue }
            let humans = oauth.channelHumanIds(channelId: channel.id).filter { memberIds.contains($0) }
            let agents = oauth.channelAgentIds(channelId: channel.id).filter { agentIds.contains($0) }
            channels.append((channel.id, channel.name, humans, agents))
        }
        var edges: [String] = []
        var humanChannelIds: [String: [String]] = [:]
        var agentChannelIds: [String: [String]] = [:]
        var channelsJSON: [String] = []
        for channel in channels {
            for human in channel.humans {
                humanChannelIds[human, default: []].append(channel.id)
                edges.append("{\"channelId\":\(jsonString(channel.id)),\"memberType\":\"human\",\"memberId\":\(jsonString(human))}")
            }
            for agent in channel.agents {
                agentChannelIds[agent, default: []].append(channel.id)
                edges.append("{\"channelId\":\(jsonString(channel.id)),\"memberType\":\"agent\",\"memberId\":\(jsonString(agent))}")
            }
            channelsJSON.append("{\"id\":\(jsonString(channel.id)),\"name\":\(jsonString(channel.name)),\"memberCount\":\(channel.humans.count + channel.agents.count)}")
        }
        let humans = memberIds.map { memberId -> String in
            let ids = (humanChannelIds[memberId] ?? []).map { jsonString($0) }.joined(separator: ",")
            return "{\"id\":\(jsonString(memberId)),\"channelIds\":[\("\(ids)")]}"
        }
        let agents = agentIds.map { agentId -> String in
            let info = oauth.agentRuntimeInfo(id: agentId)
            let ids = (agentChannelIds[agentId] ?? []).map { jsonString($0) }.joined(separator: ",")
            return "{\"id\":\(jsonString(agentId)),\"name\":\(jsonString(info?.name ?? "")),\"channelIds\":[\("\(ids)")]}"
        }
        return Self.json(200, "{\"humans\":[\("\(humans.joined(separator: ","))")],\"agents\":[\("\(agents.joined(separator: ","))")],\"channels\":[\("\(channelsJSON.joined(separator: ","))")],\"edges\":[\("\(edges.joined(separator: ","))")]}")
    }

    public func uploadServerAvatar(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let key = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let avatarUrl = "/api/avatars/server-\(serverId)/\(key).webp"
        oauth.setServerAvatar(id: serverId, avatarUrl: avatarUrl)
        return Self.json(200, "{\"avatarUrl\":\(jsonString(avatarUrl))}")
    }

}
