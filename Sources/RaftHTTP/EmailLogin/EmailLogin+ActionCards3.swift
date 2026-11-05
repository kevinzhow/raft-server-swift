import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {
    public func markActionCardExecuted(authorization: String?, serverId: String, messageId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        if oauth.memberRole(serverId: serverId, userId: userId) == "guest" {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let stored = actionCardRecords[messageId]
        lock.unlock()
        guard let stored else {
            return Self.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
        }
        if let refusal = actionCardWriteAuthorization(userId: userId, card: stored) { return refusal }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        guard let result = object["result"] as? [String: Any], let kind = result["kind"] as? String else {
            return Self.json(400, "{\"error\":\"A result is required\",\"code\":\"INVALID_RESULT\"}")
        }
        if stored.actionType == "channel:create", kind != "channel" {
            return Self.json(409, "{\"error\":\"The result kind does not match this action\",\"code\":\"INCOMPATIBLE_RESULT\"}")
        }
        lock.lock()
        guard var card = actionCardRecords[messageId] else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
        }
        if card.state != "executed" {
            card.state = "executed"
            card.executedByUserId = userId
            actionCardRecords[messageId] = card
        }
        let metadata = actionCardMetadataLocked(messageId: messageId) ?? "{\"kind\":\"action-card\",\"state\":\"executed\"}"
        lock.unlock()
        return Self.json(200, "{\"messageId\":\(jsonString(messageId)),\"metadata\":\(metadata)}")
    }

}
