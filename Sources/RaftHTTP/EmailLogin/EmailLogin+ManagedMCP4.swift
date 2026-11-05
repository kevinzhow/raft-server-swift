import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {
    public func detachProviderAgent(authorization: String?, serverId: String, connectionId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard agentId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return Self.json(400, "{\"error\":\"Invalid agent id\"}")
        }
        lock.lock()
        let known = providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assigned = providerAssignments.contains { $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId }
        lock.unlock()
        guard known else {
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        guard assigned else {
            return Self.json(404, "{\"error\":\"Provider agent assignment not found\"}")
        }
        let live = oauth.providerAgentInfo(serverId: serverId, agentId: agentId).map { !$0.deleted } ?? false
        if live {
            return Self.json(409, "{\"error\":\"The Agent still uses this provider connection\",\"code\":\"provider_connection_assignment_active\"}")
        }
        lock.lock()
        providerAssignments.removeAll { $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func deleteProviderConnection(authorization: String?, serverId: String, connectionId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let known = providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assignments = providerAssignments.filter { $0.connectionId == connectionId && $0.serverId == serverId }
        lock.unlock()
        guard known else {
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        let liveAssignments = assignments.filter { assignment in
            oauth.providerAgentInfo(serverId: serverId, agentId: assignment.agentId).map { !$0.deleted } ?? false
        }
        guard liveAssignments.isEmpty else {
            return Self.json(409, "{\"error\":\"Agents still use this provider connection\",\"code\":\"provider_connection_assignment_active\"}")
        }
        lock.lock()
        providerConnections.removeAll { $0.id == connectionId && $0.serverId == serverId }
        providerAssignments.removeAll { $0.connectionId == connectionId && $0.serverId == serverId }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }


    public struct PushRegistration: Sendable {
        public var installationId: String
        public var provider: String
        public var env: String
        public var topic: String
        public var deviceToken: String
        public var appVersion: String?
        public var userId: String?
        public var serverId: String?
        public var sessionFamilyId: String?
        public var revokeCapability: String
    }





}
