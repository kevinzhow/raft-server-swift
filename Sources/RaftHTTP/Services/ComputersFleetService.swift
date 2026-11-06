import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Computer fleet: machine registration surfaces, Computer
/// attach/adoption, runner control and the legacy machine roster.
///
/// These handlers were lifted from `EmailLogin+ComputersUsage1.swift`.

public struct ComputersFleetService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {

    public func deleteMachineWorkspace(authorization: String?, serverId: String, machineId: String, directoryName: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found in this server\"}")
        }
        let canManage = role == "owner" || role == "admin" || machine.userId == userId
        let ownsDirectory = agentMachineIds[directoryName] == machineId
        lock.unlock()
        guard canManage else {
            return Self.json(403, "{\"error\":\"The `controlComputers` capability or machine creator authority is required to delete machine workspaces\"}")
        }
        guard ownsDirectory, let agent = oauth.agentRuntimeInfo(id: directoryName), agent.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Workspace not found\"}")
        }
        lock.lock()
        deletedMachineWorkspaces.insert("\(machineId)\n\(directoryName)")
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func listServerMachines(authorization: String?, serverId: String) -> HTTPReply {        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let rows = machines.filter { $0.serverId == serverId }
        let latest = latestComputerRelease
        let policies = machineBroadcastPolicies
        let attachers = computerAttachers
        let computerVersions = computers.reduce(into: [String: String?]()) { result, computer in
            if let machineId = computer.machineId { result[machineId] = computer.version }
        }
        let assignments = agentMachineIds
        let accountsSnapshot = accounts
        let remoteUpgradeDisabled = remoteUpgradeDisabledServers.contains(serverId)
        lock.unlock()
        let memberIds = Set(oauth.memberIdsWithRoles(serverId: serverId).map(\.id))
        let json = rows.map { machine -> String in
            let policy = policies[machine.id]
            let linked = computerVersions.keys.contains(machine.id)
            let upgrade: String
            let policyJSON: String
            if !linked {
                upgrade = "null"
                policyJSON = "null"
            } else if remoteUpgradeDisabled {
                upgrade = "false"
                policyJSON = "{\"eligibility\":\"no_broadcast\",\"targetVersion\":null,\"policyRevision\":null,\"reasonCode\":\"broadcast_disabled\"}"
            } else {
                upgrade = (policy != nil && latest != nil) ? "true" : "false"
                policyJSON = policy ?? "{\"eligibility\":\"ineligible\",\"targetVersion\":null,\"policyRevision\":null,\"reasonCode\":\"policy_row_missing\"}"
            }
            let agentCount = assignments.filter { agentId, machineId in
                machineId == machine.id && oauth.agentRuntimeInfo(id: agentId).map { !$0.deleted } == true
            }.count
            let account = accountsSnapshot.values.first { $0.id == machine.userId }
            let creatorJSON: String
            if memberIds.contains(machine.userId), let account {
                let gravatar = Self.sha256(account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                creatorJSON = "{\"type\":\"human\",\"id\":\(jsonString(account.id)),\"name\":\(jsonString(account.name)),\"displayName\":\(account.displayName.map(jsonString) ?? "null"),\"avatarUrl\":\(account.avatarUrl.map(jsonString) ?? "null"),\"gravatarHash\":\(jsonString(gravatar))}"
            } else {
                creatorJSON = "null"
            }
            let runtimes = machine.runtimes.map(jsonString).joined(separator: ",")
            return "{\"id\":\(jsonString(machine.id)),\"name\":\(jsonString(machine.name)),\"userId\":\(jsonString(machine.userId)),\"description\":\(machine.description.map { jsonString($0) } ?? "null"),\"isComputer\":\(linked ? "true" : "false"),\"computerAttachedByCurrentUser\":\((attachers[machine.id] == userId) ? "true" : "false"),\"agentCount\":\(agentCount),\"creator\":\(creatorJSON),\"runtimes\":[\(runtimes)],\"computerUpgradeAvailable\":\(upgrade),\"computerBroadcastPolicy\":\(policyJSON)}"
        }.joined(separator: ",")
        let latestVersionJSON = latest.map { jsonString($0.version) } ?? "null"
        let notesJSON = latest.map { $0.notesJSON } ?? "null"
        return Self.json(200, "{\"machines\":[\(json)],\"latestComputerVersion\":\(latestVersionJSON),\"latestComputerReleaseNotes\":\(notesJSON)}")
    }

    public func patchServerMachine(authorization: String?, serverId: String, machineId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let index = machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found\"}")
        }
        if role != "owner", role != "admin", machines[index].userId != userId {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        if let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
           let description = object["description"] as? String {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            machines[index].description = trimmed.isEmpty ? nil : trimmed
        }
        let machine = machines[index]
        lock.unlock()
        emitRealtime("server:\(serverId)", "machine:updated", "{\"serverId\":\(jsonString(serverId)),\"machineId\":\(jsonString(machineId))}")
        return Self.json(200, "{\"id\":\(jsonString(machine.id)),\"name\":\(jsonString(machine.name)),\"description\":\(machine.description.map { jsonString($0) } ?? "null")}")
    }

    public func rotateServerMachineKey(authorization: String?, serverId: String, machineId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let index = machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found\"}")
        }
        if role != "owner", role != "admin", machines[index].userId != userId {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        machines[index].apiKey = Self.machineAPIKeyMaterial()
        let key = machines[index].apiKey ?? ""
        lock.unlock()
        return Self.json(200, "{\"apiKey\":\(jsonString(key))}")
    }

    public func attachComputer(authorization: String?, body: String) -> HTTPReply {
        guard computerAttachEnabled() else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        guard let serverSlug = object["serverSlug"] as? String, !serverSlug.isEmpty else {
            return Self.json(400, "{\"error\":\"serverSlug is required\",\"code\":\"server_slug_required\"}")
        }
        guard let serverId = oauth.serverIdForSlug(serverSlug),
              let details = oauth.serverDetailsValue(id: serverId),
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(403, "{\"error\":\"Not authorized\",\"code\":\"not_authorized\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"This action requires an admin or the owner\",\"code\":\"requires_admin\"}")
        }
        let requestedName = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = requestedName.isEmpty ? "raft-computer" : requestedName
        lock.lock()
        let collides = computers.contains { computer in
            computer.revokedAt == nil
                && computer.serverId == serverId
                && computer.name == name
                && computerAttachers[computer.machineId ?? ""] == userId
        }
        lock.unlock()
        if collides {
            return Self.json(409, "{\"error\":\"A Computer with this name already exists\",\"code\":\"COMPUTER_NAME_COLLISION\"}")
        }
        let machineId = registerMachine(serverId: serverId, userId: userId, name: name)
        let apiKey = Self.computerAPIKeyMaterial()
        lock.lock()
        let computerId = UUID().uuidString.lowercased()
        computers.append((id: computerId, serverId: serverId, name: name, apiKey: apiKey, machineId: machineId, revokedAt: nil, online: false, version: nil))
        computerAttachers[machineId] = userId
        lock.unlock()
        return Self.json(201, "{\"apiKey\":\(jsonString(apiKey)),\"serverMachineId\":\(jsonString(computerId)),\"machineId\":\(jsonString(machineId)),\"serverId\":\(jsonString(serverId)),\"serverSlug\":\(jsonString(details.slug)),\"name\":\(jsonString(name)),\"resumed\":false}")
    }

    /// `POST /api/computer/adopt-legacy`. One-time migration from a legacy
    /// `sk_machine_*` / `sk_daemon_*` daemon to a fresh `sk_computer_*`
    /// principal. Authority depends on the selector: possession of the raw
    /// legacy key, a row from the caller's user-scoped legacy roster, or (with
    /// `registerMachines`) a daemon row on a Server the caller manages. All
    /// three mint a Computer attachment, so all three need the same
    /// owner/admin capability as `/api/computer/attach`.
    public func adoptLegacyComputer(authorization: String?, body: String) -> HTTPReply {
        guard computerAttachEnabled() else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Authentication required\",\"code\":\"auth_required\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        func text(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let hasRawLegacyKey = text("legacyApiKey") != nil
        let hasRosterIdentity = text("serverSlug") != nil && text("legacyMachineId") != nil && text("apiKeyFingerprint") != nil
        let hasDaemonIdentity = text("serverSlug") != nil && text("daemonId") != nil
        guard hasRawLegacyKey || hasRosterIdentity || hasDaemonIdentity else {
            return Self.json(400, "{\"error\":\"legacyApiKey, fingerprint roster identity, or daemonId identity is required\",\"code\":\"legacy_api_key_required\"}")
        }
        var requestedName: String?
        if let rawName = object["name"], !(rawName is NSNull) {
            guard let name = rawName as? String, !name.isEmpty, name.count <= 200 else {
                return Self.json(400, "{\"error\":\"name must be a non-empty string up to 200 chars\",\"code\":\"name_invalid\"}")
            }
            requestedName = name
        }
        if hasRosterIdentity {
            return adoptLegacyComputerByRoster(
                userId: userId,
                serverSlug: text("serverSlug") ?? "",
                legacyMachineId: text("legacyMachineId") ?? "",
                fingerprint: text("apiKeyFingerprint") ?? "",
                requestedName: requestedName
            )
        }
        if hasDaemonIdentity {
            return adoptLegacyComputerByDaemonId(
                userId: userId,
                serverSlug: text("serverSlug") ?? "",
                daemonId: text("daemonId") ?? "",
                requestedName: requestedName
            )
        }
        return adoptLegacyComputerByRawKey(
            userId: userId,
            rawKey: text("legacyApiKey") ?? "",
            requestedName: requestedName
        )
    }

    func adoptLegacyComputerByRawKey(userId: String, rawKey: String, requestedName: String?) -> HTTPReply {
        // The legacy auth middleware accepts both prefixes, so a real daemon in
        // the wild may still be running on either one.
        guard rawKey.hasPrefix("sk_machine_") || rawKey.hasPrefix("sk_daemon_") else {
            return Self.json(401, "{\"error\":\"Invalid legacy machine key\",\"code\":\"legacy_key_invalid\"}")
        }
        lock.lock()
        let matched = machines.first { $0.apiKey == rawKey }?.id
        lock.unlock()
        guard let matched else {
            return Self.json(401, "{\"error\":\"Invalid legacy machine key\",\"code\":\"legacy_key_invalid\"}")
        }
        // Possession is proven by the key itself; replay stays a hard conflict.
        return adoptMatchedLegacyMachine(
            userId: userId,
            machineId: matched,
            requestedName: requestedName,
            allowAlreadyMigratedResume: false
        )
    }

    func adoptLegacyComputerByRoster(
        userId: String,
        serverSlug: String,
        legacyMachineId: String,
        fingerprint: String,
        requestedName: String?
    ) -> HTTPReply {
        guard fingerprint.wholeMatch(of: /^[0-9a-fA-F]{16}$/) != nil else {
            return Self.json(401, "{\"error\":\"Invalid legacy machine key\",\"code\":\"legacy_key_invalid\"}")
        }
        guard let serverId = oauth.serverIdForSlug(serverSlug),
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else {
            return Self.json(403, "{\"error\":\"Not authorized to adopt this machine\",\"code\":\"not_authorized\"}")
        }
        // The roster identity is user-scoped: selecting somebody else's row is
        // the same 401 as an unknown key so the roster cannot be probed.
        lock.lock()
        let matched = machines.first { machine in
            machine.id == legacyMachineId
                && machine.serverId == serverId
                && machine.userId == userId
                && machine.apiKeyFingerprint?.lowercased() == fingerprint.lowercased()
        }?.id
        lock.unlock()
        guard let matched else {
            return Self.json(401, "{\"error\":\"Invalid legacy machine key\",\"code\":\"legacy_key_invalid\"}")
        }
        return adoptMatchedLegacyMachine(
            userId: userId,
            machineId: matched,
            requestedName: requestedName,
            allowAlreadyMigratedResume: true
        )
    }

    func adoptLegacyComputerByDaemonId(
        userId: String,
        serverSlug: String,
        daemonId: String,
        requestedName: String?
    ) -> HTTPReply {
        guard let serverId = oauth.serverIdForSlug(serverSlug),
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(403, "{\"error\":\"Not authorized to adopt this machine\",\"code\":\"not_authorized\"}")
        }
        let managesMachines = role == "owner" || role == "admin"
        lock.lock()
        let row = machines.first { $0.id == daemonId && $0.serverId == serverId }
        lock.unlock()
        guard let row else {
            // Managers learn the row is missing; everybody else collapses into
            // the capability refusal so the route cannot enumerate identities.
            return managesMachines
                ? Self.json(404, "{\"error\":\"Legacy machine was not found on this server\",\"code\":\"legacy_machine_not_found\"}")
                : Self.json(403, "{\"error\":\"Adopting a Computer requires the admin or owner role on this server\",\"code\":\"requires_admin\"}")
        }
        if row.userId != userId && !managesMachines {
            return Self.json(403, "{\"error\":\"Adopting a Computer requires the admin or owner role on this server\",\"code\":\"requires_admin\"}")
        }
        return adoptMatchedLegacyMachine(
            userId: userId,
            machineId: row.id,
            requestedName: requestedName,
            allowAlreadyMigratedResume: true
        )
    }

    func adoptMatchedLegacyMachine(
        userId: String,
        machineId: String,
        requestedName: String?,
        allowAlreadyMigratedResume: Bool
    ) -> HTTPReply {
        lock.lock()
        let snapshot = machines.first { $0.id == machineId }
        lock.unlock()
        guard let snapshot else {
            return Self.json(401, "{\"error\":\"Invalid legacy machine key\",\"code\":\"legacy_key_invalid\"}")
        }
        guard let role = oauth.memberRole(serverId: snapshot.serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not authorized to adopt this machine\",\"code\":\"not_authorized\"}")
        }
        let managesMachines = role == "owner" || role == "admin"
        if snapshot.userId != userId && !managesMachines {
            return Self.json(403, "{\"error\":\"Adopting a Computer requires the admin or owner role on this server\",\"code\":\"requires_admin\"}")
        }
        let name = Self.adoptedComputerName(requestedName, fallback: snapshot.name)
        lock.lock()
        guard let machineIndex = machines.firstIndex(where: { $0.id == machineId }) else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Invalid legacy machine key\",\"code\":\"legacy_key_invalid\"}")
        }
        let serverId = machines[machineIndex].serverId
        let liveComputerIndex = computers.firstIndex { computer in
            computer.machineId == machineId && computer.serverId == serverId && computer.revokedAt == nil
        }
        if machines[machineIndex].legacyKeyMigratedAt != nil {
            // Roster/daemon selection may retry after the server committed: the
            // setup did not finish locally, so resume the linked Computer with
            // a rotated credential instead of demanding the legacy key again.
            guard allowAlreadyMigratedResume, let liveComputerIndex else {
                lock.unlock()
                return Self.json(409, "{\"error\":\"This machine has already been migrated to a Computer attachment\",\"code\":\"legacy_machine_key_migrated\"}")
            }
            let apiKey = Self.computerAPIKeyMaterial()
            computers[liveComputerIndex] = (
                id: computers[liveComputerIndex].id,
                serverId: serverId,
                name: name,
                apiKey: apiKey,
                machineId: machineId,
                revokedAt: nil,
                online: computers[liveComputerIndex].online,
                version: computers[liveComputerIndex].version
            )
            let computerId = computers[liveComputerIndex].id
            lock.unlock()
            return Self.adoptedComputerReply(apiKey: apiKey, computerId: computerId, machineId: machineId, serverId: serverId, resumed: true)
        }
        // Atomic mark: only the first caller flips the flag, so concurrent
        // adoption requests collapse into exactly one winner.
        machines[machineIndex].legacyKeyMigratedAt = Date()
        let apiKey = Self.computerAPIKeyMaterial()
        let computerId: String
        let resumed: Bool
        if let liveComputerIndex {
            computers[liveComputerIndex] = (
                id: computers[liveComputerIndex].id,
                serverId: serverId,
                name: name,
                apiKey: apiKey,
                machineId: machineId,
                revokedAt: nil,
                online: computers[liveComputerIndex].online,
                version: computers[liveComputerIndex].version
            )
            computerId = computers[liveComputerIndex].id
            resumed = true
        } else {
            computerId = UUID().uuidString.lowercased()
            computers.append((id: computerId, serverId: serverId, name: name, apiKey: apiKey, machineId: machineId, revokedAt: nil, online: false, version: nil))
            resumed = false
        }
        computerAttachers[machineId] = userId
        lock.unlock()
        return Self.adoptedComputerReply(apiKey: apiKey, computerId: computerId, machineId: machineId, serverId: serverId, resumed: resumed)
    }

    /// `POST /internal/computer/runners/:agentId/credentials`. A live Computer
    /// mints an agent credential for a runner of its own machine only.
    public func computerMintRunnerCredential(authorization: String?, agentId: String, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Invalid computer credential\"}")
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        guard case .linked(let computerId, let machineId) = computerCredential(apiKey: apiKey) else {
            return Self.json(401, "{\"error\":\"Invalid computer credential\"}")
        }
        lock.lock()
        guard let computer = computers.first(where: { $0.id == computerId }),
              let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted,
              agent.serverId == computer.serverId,
              agentMachineIds[agentId] == machineId
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Agent not found\",\"code\":\"agent_missing\"}")
        }
        lock.unlock()
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let allowed = ["send", "read", "mentions", "tasks", "reactions", "server", "channels", "knowledge", "mcp", "raftbench"]
        let scopes: [String]
        if let raw = object["scopes"] {
            guard let list = raw as? [Any], list.allSatisfy({ $0 is String }) else {
                return Self.json(400, "{\"error\":\"scopes must be an array of capability literals\",\"code\":\"scopes_invalid\"}")
            }
            let values = Set(list.compactMap { $0 as? String })
            guard values.allSatisfy({ allowed.contains($0) }) else {
                let expected = allowed.joined(separator: ", ")
                return Self.json(400, "{\"error\":\"scopes must each be one of: \(expected)\",\"code\":\"scopes_invalid\"}")
            }
            guard !values.isEmpty else {
                return Self.json(400, "{\"error\":\"scopes must include at least one capability\",\"code\":\"scopes_empty\"}")
            }
            scopes = values.sorted()
        } else {
            scopes = allowed
        }
        var name = "computer-runner"
        if let rawName = object["name"], !(rawName is NSNull) {
            guard let text = rawName as? String, !text.isEmpty, text.count <= 200 else {
                return Self.json(400, "{\"error\":\"name must be a non-empty string up to 200 chars\",\"code\":\"name_invalid\"}")
            }
            name = text
        }
        let minted = mintAgentCredential(agentId: agentId, scopes: scopes, name: name)
        lock.lock()
        let credentialId = agentCredentials[minted]?.id ?? UUID().uuidString.lowercased()
        lock.unlock()
        let scopeJSON = scopes.map { jsonString($0) }.joined(separator: ",")
        return Self.json(201, "{\"credentialId\":\(jsonString(credentialId)),\"apiKey\":\(jsonString(minted)),\"scopes\":[\(scopeJSON)],\"agentId\":\(jsonString(agentId)),\"agentName\":\(jsonString(agent.name)),\"serverId\":\(jsonString(agent.serverId))}")
    }

    func computerCredentialValid(_ authorization: String?) -> Bool {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return false }
        let key = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        defer { lock.unlock() }
        return computers.contains { $0.apiKey == key && $0.revokedAt == nil }
    }

    /// Resolves the Computer behind a `sk_computer_*` bearer to its attached
    /// machine. A revoked, unknown or machine-unlinked credential yields nil.
    func computerRunnerContext(_ authorization: String?) -> (computerId: String, serverId: String, machineId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        defer { lock.unlock() }
        guard let computer = computers.first(where: { $0.apiKey == apiKey && $0.revokedAt == nil }),
              let machineId = computer.machineId,
              machines.contains(where: { $0.id == machineId })
        else { return nil }
        return (computer.id, computer.serverId, machineId)
    }

    /// `GET /internal/computer/runners`. The §12 control-plane whitelist is
    /// enforced here, in the projection, so no agent record field (session ids,
    /// env vars, runtime config) can ever reach the wire — a client-side filter
    /// would not protect against a server dump bug. Default scope is this
    /// Computer's machine; `?scope=server` keeps the legacy server-wide view.
    public func computerRunners(authorization: String?, scope: String? = nil) -> HTTPReply {
        guard let context = computerRunnerContext(authorization) else {
            return Self.json(401, "{\"error\":\"Invalid computer credential\"}")
        }
        let serverWide = scope == "server"
        lock.lock()
        let machineByAgent = agentMachineIds
        lock.unlock()
        let agents = oauth.serverAgents(serverId: context.serverId)
            .filter { !$0.deleted }
            .sorted { $0.name < $1.name }
        var rows: [String] = []
        for agent in agents {
            if !serverWide, machineByAgent[agent.id] != context.machineId { continue }
            let status = agent.status
            let model = Self.runnerModel(from: agent.runtimeConfigJSON)
            rows.append("{\"agentId\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"status\":\(jsonString(status)),\"model\":\(jsonString(model)),\"runtime\":\(jsonString(agent.runtime))}")
        }
        return Self.json(200, "{\"whitelist\":[\"agentId\",\"name\",\"status\",\"model\",\"runtime\"],\"runners\":[\(rows.joined(separator: ","))]}")
    }

    /// `POST /internal/computer/runners/:agentId/stop`. A Computer stops only a
    /// runner bound to its own machine on its own Server; anything else answers
    /// the uniform missing-agent 404 so other machines' and servers' agents
    /// cannot be probed.
    public func computerStopRunner(authorization: String?, agentId: String) -> HTTPReply {
        guard let context = computerRunnerContext(authorization) else {
            return Self.json(401, "{\"error\":\"Invalid computer credential\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId),
              !agent.deleted,
              agent.serverId == context.serverId
        else {
            return Self.json(404, "{\"error\":\"Agent not found\",\"code\":\"agent_missing\"}")
        }
        lock.lock()
        let bound = agentMachineIds[agentId] == context.machineId
        lock.unlock()
        guard bound else {
            return Self.json(404, "{\"error\":\"Agent not found\",\"code\":\"agent_missing\"}")
        }
        lock.lock()
        if serverAgents[agentId] != nil { serverAgents[agentId]?.status = "inactive" }
        lock.unlock()
        return Self.json(200, "{\"agentId\":\(jsonString(agentId))}")
    }

    /// `DELETE /internal/computer/runners/:agentId/credentials/:credentialId`.
    /// Same machine binding as the stop surface: another machine's runner is a
    /// uniform missing-agent 404, never a credential oracle.
    public func computerRevokeRunnerCredential(authorization: String?, agentId: String, credentialId: String) -> HTTPReply {
        guard let context = computerRunnerContext(authorization) else {
            return Self.json(401, "{\"error\":\"Invalid computer credential\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId),
              !agent.deleted,
              agent.serverId == context.serverId
        else {
            return Self.json(404, "{\"error\":\"Agent not found\",\"code\":\"agent_missing\"}")
        }
        lock.lock()
        let bound = agentMachineIds[agentId] == context.machineId
        var revokedCredentialId: String?
        if bound, let entry = agentCredentials.first(where: { $0.value.id == credentialId && $0.value.agentId == agentId }) {
            agentCredentials[entry.key]?.revokedAt = entry.value.revokedAt ?? Date()
            revokedCredentialId = entry.value.id
        }
        lock.unlock()
        guard bound else {
            return Self.json(404, "{\"error\":\"Agent not found\",\"code\":\"agent_missing\"}")
        }
        guard let revokedCredentialId else {
            return Self.json(404, "{\"error\":\"Credential not found\",\"code\":\"credential_missing\"}")
        }
        return Self.json(200, "{\"agentId\":\(jsonString(agentId)),\"credentialId\":\(jsonString(revokedCredentialId)),\"revoked\":true}")
    }

    public func setMachineRuntimeModels(machineId: String, runtime: String, models: [(id: String, label: String)]) {
        lock.lock()
        machineRuntimeModels[machineId, default: [:]][runtime] = (models, Date())
        lock.unlock()
    }

    public func computerAction(authorization: String?, serverId: String, machineId: String, action: String, body: String = "") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard ["restart", "start", "stop", "upgrade"].contains(action) else {
            return Self.json(400, "{\"error\":\"Unknown computer action\",\"code\":\"unknown_action\"}")
        }
        if action == "upgrade" {
            lock.lock()
            let disabled = remoteUpgradeDisabledServers.contains(serverId)
            lock.unlock()
            guard !disabled else {
                return Self.json(403, "{\"error\":\"Remote upgrade is disabled for this server\",\"code\":\"remote_upgrade_disabled\"}")
            }
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            let target = (object?["targetVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !target.isEmpty else {
                return Self.json(400, "{\"error\":\"targetVersion is required\",\"code\":\"invalid_target_version\"}")
            }
        }
        lock.lock()
        let machineExists = machines.contains { $0.id == machineId && $0.serverId == serverId }
        let linked = computers.filter { candidate in
            candidate.serverId == serverId
                && candidate.machineId == machineId
                && candidate.revokedAt == nil
        }
        let computer = linked.first { $0.online } ?? linked.first
        lock.unlock()
        guard machineExists else {
            return Self.json(404, "{\"error\":\"Machine not found\"}")
        }
        guard let computer else {
            return Self.json(409, "{\"error\":\"Machine is not a Computer\",\"code\":\"not_a_computer\"}")
        }
        guard computer.online else {
            return Self.json(409, "{\"error\":\"Computer is offline\",\"code\":\"computer_offline\"}")
        }
        guard let version = computer.version, !version.isEmpty else {
            return Self.json(409, "{\"error\":\"Raft couldn't verify the Computer version. Reconnect the Computer, then try again.\",\"code\":\"computer_control_unsupported\"}")
        }
        let requestId = UUID().uuidString.lowercased()
        if action == "upgrade" {
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            let target = (object?["targetVersion"] as? String) ?? ""
            if let sender = computerUpgradeSender, !sender(machineId, target, requestId) {
                return Self.json(409, "{\"error\":\"Computer is offline\",\"code\":\"computer_offline\"}")
            }
        }
        return Self.json(200, "{\"ok\":true,\"action\":\(jsonString(action)),\"requestId\":\(jsonString(requestId)),\"operationId\":\(jsonString(UUID().uuidString.lowercased())),\"computerVersion\":\(jsonString(version))}")
    }

    public func machineRuntimeRescan(authorization: String?, serverId: String, machineId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        let online = machineOnline[machineId] == true
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or machine creator authority is required to rescan runtimes\"}")
        }
        guard online else {
            return Self.json(409, "{\"error\":\"Computer is offline\"}")
        }
        return Self.json(200, "{\"requested\":true}")
    }

    public func modelLabelCatalog(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let serverMachines = machines.filter { $0.serverId == serverId }
        let snapshot = machineRuntimeModels
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let machinesJSON = serverMachines.map { machine -> String in
            let runtimes = snapshot[machine.id] ?? [:]
            let runtimesJSON = runtimes.map { runtime, entry -> String in
                let models = entry.models.map { model in
                    "{\"id\":\(jsonString(model.id)),\"label\":\(jsonString(model.label))}"
                }.joined(separator: ",")
                return "\(jsonString(runtime)):{\"models\":[\(models)],\"updatedAt\":\(jsonString(formatter.string(from: entry.updatedAt)))}"
            }.joined(separator: ",")
            return "\(jsonString(machine.id)):{\"runtimes\":{\(runtimesJSON)}}"
        }.joined(separator: ",")
        return Self.json(200, "{\"machines\":{\(machinesJSON)}}")
    }

    public func machineCount(serverId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return machines.filter { $0.serverId == serverId }.count
    }

    public func deleteServerMachine(authorization: String?, serverId: String, machineId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let index = machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found\"}")
        }
        if role != "owner", role != "admin", machines[index].userId != userId {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let activeMigration = activeAgentMigrations.values.contains { migration in
            migration.sourceMachineId == machineId
                && !["completed", "failed", "aborted", "cancelled"].contains(migration.state)
        }
        if activeMigration {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Cannot delete computer while an agent migration is in progress. Wait for it to finish or abort it first.\",\"code\":\"MACHINE_HAS_ACTIVE_MIGRATION\"}")
        }
        let terminalStates: Set<String> = ["completed", "failed", "aborted", "cancelled"]
        var profileRemovals: [String] = []
        var profileUpdates: [String: AgentRuntimeProfileFact] = [:]
        for (agentId, profile) in agentRuntimeProfiles {
            let agent = oauth.agentRuntimeInfo(id: agentId)
            let agentActive = agent != nil && agent?.deleted == false
            if profile.machineId == machineId {
                if !agentActive {
                    profileRemovals.append(agentId)
                    continue
                }
                let assignment = agentMachineIds[agentId]
                let proof = assignment.map { target in
                    activeAgentMigrations.values.contains { migration in
                        migration.agentId == agentId
                            && migration.sourceMachineId == machineId
                            && migration.targetMachineId == target
                            && terminalStates.contains(migration.state)
                            && migration.state == "completed"
                    }
                } ?? false
                if proof, profile.pendingKind == nil {
                    profileRemovals.append(agentId)
                } else {
                    lock.unlock()
                    return Self.json(409, "{\"error\":\"Cannot delete computer while runtime profiles still reference active agents. Remove or migrate related agents first.\",\"code\":\"MACHINE_HAS_ACTIVE_RUNTIME_PROFILE\"}")
                }
            } else if profile.pendingBeforeMachineId == machineId {
                if !agentActive {
                    var updated = profile
                    updated.pendingBeforeMachineId = nil
                    profileUpdates[agentId] = updated
                    continue
                }
                let proof = activeAgentMigrations.values.contains { migration in
                    migration.agentId == agentId
                        && migration.sourceMachineId == machineId
                        && migration.targetMachineId == profile.machineId
                        && migration.state == "completed"
                }
                if proof {
                    var updated = profile
                    updated.pendingBeforeMachineId = nil
                    profileUpdates[agentId] = updated
                } else {
                    lock.unlock()
                    return Self.json(409, "{\"error\":\"Cannot delete computer while runtime profiles still reference active agents. Remove or migrate related agents first.\",\"code\":\"MACHINE_HAS_ACTIVE_RUNTIME_PROFILE\"}")
                }
            }
        }
        for agentId in profileRemovals {
            agentRuntimeProfiles.removeValue(forKey: agentId)
        }
        for (agentId, profile) in profileUpdates {
            agentRuntimeProfiles[agentId] = profile
        }
        machines.remove(at: index)
        for computerIndex in computers.indices where computers[computerIndex].machineId?.caseInsensitiveCompare(machineId) == .orderedSame {
            computers[computerIndex].machineId = nil
            computers[computerIndex].revokedAt = Date()
        }
        lock.unlock()
        emitRealtime("server:\(serverId)", "machine:updated", "{\"serverId\":\(jsonString(serverId)),\"machineId\":\(jsonString(machineId))}")
        return Self.json(200, "{\"ok\":true}")
    }

    /// `sha256(apiKey)` hex, first 16 characters — the wire identity the legacy
    /// daemon also writes into its local `owner.json`, so the roster picker and
    /// adoption intersect on the same value.
    static func apiKeyFingerprint(_ apiKey: String) -> String {
        String(sha256Hex(apiKey).prefix(16))
    }

    /// `GET /api/computer/legacy-machines`. A daemon-adoption roster scoped to
    /// the caller's own machines on one Server. Unknown, deleted and
    /// non-member servers collapse into one 403 so the roster cannot enumerate
    /// servers, and credentials never leave through this surface.
    public func legacyMachines(authorization: String?, serverSlug: String?, includeAll: Bool) -> HTTPReply {
        guard computerAttachEnabled() else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        guard let serverSlug, !serverSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.json(400, "{\"error\":\"serverSlug is required\",\"code\":\"server_slug_required\"}")
        }
        guard let serverId = oauth.serverIdForSlug(serverSlug),
              let details = oauth.serverDetailsValue(id: serverId),
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else {
            return Self.json(403, "{\"error\":\"Not authorized\",\"code\":\"not_authorized\"}")
        }
        lock.lock()
        let rows = machines
            .filter { machine in
                machine.serverId == serverId
                    && machine.userId == userId
                    && (includeAll || machine.apiKeyFingerprint != nil)
            }
            .sorted { $0.name < $1.name }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries = rows.map { machine -> String in
            let seenJSON = machine.lastSeenAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
            let hostnameJSON = machine.hostname.map(jsonString) ?? "null"
            let migratedJSON = machine.legacyKeyMigratedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
            let fingerprint = (machine.apiKeyFingerprint != nil && includeAll == false)
                ? machine.apiKeyFingerprint.map(jsonString) ?? "null"
                : nil
            var entry = "{\"daemonId\":\(jsonString(machine.id)),\"machineName\":\(jsonString(machine.name)),\"hostname\":\(hostnameJSON),\"lastSeenAt\":\(seenJSON),\"hasFingerprint\":\(machine.apiKeyFingerprint != nil),\"legacyKeyMigratedAt\":\(migratedJSON)"
            if let fingerprint { entry += ",\"apiKeyFingerprint\":\(fingerprint)" }
            entry += "}"
            return entry
        }
        lock.unlock()
        return Self.json(200, "{\"serverId\":\(jsonString(serverId)),\"serverSlug\":\(jsonString(details.slug)),\"entries\":[\(entries.joined(separator: ","))]}")
    }

    public func computerLifecycleOperation(
        authorization: String?,
        serverId: String,
        machineId: String,
        body: String
    ) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let action = object["action"] as? String,
              ["start", "stop", "restart", "upgrade"].contains(action)
        else {
            return Self.json(400, "{\"error\":\"Unknown Computer lifecycle action\",\"code\":\"unknown_action\"}")
        }
        guard let operationId = object["operationId"] as? String, ServerScope.isUUID(operationId) else {
            return Self.json(400, "{\"error\":\"A valid operationId is required\",\"code\":\"invalid_operation_id\"}")
        }
        guard let parentOperationId = object["parentOperationId"] as? String, ServerScope.isUUID(parentOperationId) else {
            return Self.json(400, "{\"error\":\"A valid parentOperationId is required\",\"code\":\"invalid_parent_operation_id\"}")
        }
        let targetVersion = object["targetVersion"] as? String
        if action == "upgrade" {
            lock.lock()
            let disabled = remoteUpgradeDisabledServers.contains(serverId)
            lock.unlock()
            guard !disabled else {
                return Self.json(409, "{\"error\":\"Hands could not select a newer alpha release for this Computer.\",\"code\":\"broadcast_disabled\",\"policy\":{\"eligibility\":\"no_broadcast\",\"reasonCode\":\"broadcast_disabled\"}}")
            }
            if let targetVersion, targetVersion.wholeMatch(of: /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/) == nil {
                return Self.json(400, "{\"error\":\"A valid targetVersion is required only for upgrade\",\"code\":\"invalid_target_version\"}")
            }
        } else if targetVersion != nil {
            return Self.json(400, "{\"error\":\"A valid targetVersion is required only for upgrade\",\"code\":\"invalid_target_version\"}")
        }
        if let completionMode = object["completionMode"] {
            guard action == "upgrade", completionMode as? String == "legacy_k_promoted" else {
                return Self.json(400, "{\"error\":\"Unknown Computer lifecycle completion mode\",\"code\":\"invalid_completion_mode\"}")
            }
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found in this server\"}")
        }
        let computer = computers.first { $0.machineId == machineId && $0.serverId == serverId && $0.revokedAt == nil }
        let online = machineOnline[machineId] == true || computer?.online == true
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `controlComputers` capability or machine creator authority is required to control Computers\"}")
        }
        guard computer != nil else {
            return Self.json(409, "{\"error\":\"Lifecycle operations are only available for managed Computers\",\"code\":\"not_a_computer\"}")
        }
        if action == "start", online {
            return Self.json(409, "{\"error\":\"Computer is already online\",\"code\":\"computer_already_online\"}")
        }
        if action != "start", !online {
            return Self.json(409, "{\"error\":\"Computer is not online\",\"code\":\"computer_offline\"}")
        }
        var resolvedTarget = targetVersion
        if action == "upgrade", resolvedTarget == nil {
            lock.lock()
            let latest = latestComputerRelease?.version
            lock.unlock()
            guard let latest else {
                return Self.json(409, "{\"error\":\"Hands could not select a newer alpha release for this Computer.\",\"code\":\"computer_upgrade_unavailable\"}")
            }
            resolvedTarget = latest
        }
        if object["completionMode"] != nil {
            return Self.json(409, "{\"error\":\"The live Computer ready attestation is not visible yet.\",\"code\":\"computer_lifecycle_completion_ready_pending\"}")
        }
        let versionJSON = resolvedTarget.map(jsonString) ?? "null"
        return Self.json(201, "{\"operationId\":\(jsonString(operationId)),\"parentOperationId\":\(jsonString(parentOperationId)),\"serverId\":\(jsonString(serverId)),\"machineId\":\(jsonString(machineId)),\"actorUserId\":\(jsonString(userId)),\"action\":\(jsonString(action)),\"dispatchMode\":\"local\",\"connectionEpochBefore\":null,\"targetVersion\":\(versionJSON)}")
    }

}
