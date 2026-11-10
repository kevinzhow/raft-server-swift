import Foundation
import RaftHTTP
import RaftMachineSocket
import Testing
@testable import RaftServer

@Suite struct ProductionAgentExecutionWireTests {
    private func command(_ kind: String) throws -> AgentExecutionCommand {
        var body: [String: Any] = [
            "commandId": "11111111-1111-4111-8111-111111111651", "kind": kind,
            "serverId": "server", "machineId": "machine", "agentId": "agent",
            "launchId": "launch", "connectionEpochId": "epoch", "takeoverEpoch": 2,
            "breakerGeneration": 3, "humanStart": true, "status": "pending", "createdAt": 0
        ]
        if kind == "start" { body["startDispatchId"] = "dispatch" }
        if kind == "delivery" { body["deliveryId"] = "delivery"; body["channelId"] = "local-joint"; body["messageId"] = "message" }
        if kind == "notice" {
            body["deliveryId"] = "delivery"
            body["channelId"] = "onboarding-context"
            body["messageId"] = "onboarding-owner-facts-server"
            body["notice"] = ["channelName": "onboarding-context", "channelType": "channel",
                              "content": "Owner facts", "timestamp": "2026-01-01T00:00:00.000Z"]
        }
        return try JSONDecoder().decode(AgentExecutionCommand.self, from: JSONSerialization.data(withJSONObject: body))
    }

    @Test func startPublishesStableUpstreamIdentityAndScopedConfiguration() throws {
        let intent = try command("start")
        let configuration: [String: Any] = [
            "name": "Codex", "displayName": NSNull(), "description": NSNull(), "model": "configured-model",
            "runtime": "codex", "runtimeConfig": ["model": "configured-model"], "reasoningEffort": NSNull(),
            "envVars": NSNull(), "sessionId": NSNull(), "serverUrl": "https://example.com", "authToken": "",
            "agentCredentialKey": "sk_agent_fixture", "agentCredentialId": "fixture-row",
            "runtimeContext": ["agentId": "agent", "serverId": "server", "machineId": "machine"],
            "installedApps": [["name": "fixture-app"]],
            "extension": ["2": 2, "10": 10, "a": true, "B": NSNull(), "text": "é😀 a/b\n\u{1}", "fraction": 0.5]
        ]
        let config = try JSONSerialization.data(withJSONObject: configuration)
        let data = try ProductionAgentExecutionWire.start(intent, configuration: config)
        let expected: [String: Any] = ["type": "agent:start", "agentId": "agent", "config": configuration,
                                       "launchId": "launch", "startDispatchId": "dispatch", "breakerGeneration": 3,
                                       "takeoverEpoch": 2, "humanStart": true, "connectionEpochId": "epoch"]
        #expect(data == (try JSONSerialization.data(withJSONObject: expected, options: .sortedKeys)))
        #expect(data == (try ProductionAgentExecutionWire.start(intent, configuration: config)))
        let frame = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(frame["type"] as? String == "agent:start")
        #expect(frame["launchId"] as? String == "launch")
        #expect(frame["startDispatchId"] as? String == "dispatch")
        #expect(frame["connectionEpochId"] as? String == "epoch")
        #expect(frame["takeoverEpoch"] as? Int == 2)
        #expect(frame["breakerGeneration"] as? Int == 3)
        let published = try #require(frame["config"] as? [String: Any])
        #expect(published["runtime"] as? String == "codex")
        #expect((published["installedApps"] as? [[String: Any]])?.count == 1)
        let parsed = try MachineCommand(json: String(decoding: data, as: UTF8.self), expectedConnectionEpochId: "epoch")
        #expect(parsed.kind == .start)
        #expect(parsed.id == "dispatch")
        #expect(throws: MachineCommandError.disconnected) {
            try MachineCommand(json: String(decoding: data, as: UTF8.self), expectedConnectionEpochId: "replacement")
        }
        var foreign = configuration
        foreign["runtimeContext"] = ["agentId": "foreign", "serverId": "server", "machineId": "machine"]
        let invalid = try JSONSerialization.data(withJSONObject: foreign)
        #expect(throws: ProductionAgentExecutionWire.Error.invalidConfiguration) {
            try ProductionAgentExecutionWire.start(intent, configuration: invalid)
        }
        var unsupported = configuration
        unsupported["extension"] = UInt64.max
        let unrepresentable = try JSONSerialization.data(withJSONObject: unsupported)
        #expect(throws: ProductionAgentExecutionWire.Error.invalidConfiguration) {
            try ProductionAgentExecutionWire.start(intent, configuration: unrepresentable)
        }
    }

    @Test func noticePublishesTheUpstreamSystemBodyInASeqZeroDeliveryEnvelope() throws {
        let intent = try command("notice")
        let message: [String: Any] = [
            "channel_id": "onboarding-context", "channel_name": "onboarding-context",
            "channel_type": "channel", "message_id": "onboarding-owner-facts-server",
            "sender_id": "system", "sender_name": "system", "sender_type": "system",
            "content": "Owner facts", "timestamp": "2026-01-01T00:00:00.000Z",
        ]
        let input = try JSONSerialization.data(withJSONObject: message)
        let data = try ProductionAgentExecutionWire.notice(intent, message: input)
        let expected: [String: Any] = ["type": "agent:deliver", "agentId": "agent",
                                       "message": message, "seq": 0, "deliveryId": "delivery"]
        #expect(data == (try JSONSerialization.data(withJSONObject: expected, options: .sortedKeys)))
        let frame = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(frame["type"] as? String == "agent:deliver")
        #expect(frame["seq"] as? Int == 0)
        #expect(frame["deliveryId"] as? String == "delivery")
        let body = try #require(frame["message"] as? [String: Any])
        #expect(body["message_id"] as? String == "onboarding-owner-facts-server")
        #expect(body["sender_type"] as? String == "system")
        // The synthetic notice carries no stored seq; the envelope owns the 0.
        #expect(body["seq"] == nil)
        let raw = String(decoding: data, as: UTF8.self)
        let parsed = try MachineCommand(json: raw, expectedConnectionEpochId: "epoch")
        #expect(parsed.kind == .deliver)
        #expect(parsed.id == "delivery")
        #expect(parsed.deliverySequence == 0)
        var seqInBody = message
        seqInBody["seq"] = 0
        let invalid = try JSONSerialization.data(withJSONObject: seqInBody)
        #expect(throws: ProductionAgentExecutionWire.Error.invalidMessage) {
            try ProductionAgentExecutionWire.notice(intent, message: invalid)
        }
        var humanSender = message
        humanSender["sender_type"] = "human"
        let invalidSender = try JSONSerialization.data(withJSONObject: humanSender)
        #expect(throws: ProductionAgentExecutionWire.Error.invalidMessage) {
            try ProductionAgentExecutionWire.notice(intent, message: invalidSender)
        }
    }

    @Test func deliveryPublishesCanonicalMessageInLocalContextWithPrivateEpochFence() throws {
        let intent = try command("delivery")
        let message: [String: Any] = [
            "channel_id": "local-joint", "channel_name": "Joint", "channel_type": "joint",
            "message_id": "message", "sender_id": "human", "sender_name": "Human", "sender_type": "human",
            "content": "Actual stored content", "timestamp": "2026-01-01T00:00:00.000Z", "seq": 42,
            "task_status": "todo", "task_number": 7
        ]
        let input = try JSONSerialization.data(withJSONObject: message)
        let data = try ProductionAgentExecutionWire.delivery(intent, message: input, sequence: 42)
        let expected: [String: Any] = ["type": "agent:deliver", "agentId": "agent", "message": message, "seq": 42, "deliveryId": "delivery"]
        #expect(data == (try JSONSerialization.data(withJSONObject: expected, options: .sortedKeys)))
        let frame = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(frame["type"] as? String == "agent:deliver")
        #expect(frame["deliveryId"] as? String == "delivery")
        #expect(frame["seq"] as? Int == 42)
        #expect(frame["connectionEpochId"] == nil)
        let body = try #require(frame["message"] as? [String: Any])
        #expect(body["channel_id"] as? String == "local-joint")
        #expect(body["message_id"] as? String == "message")
        #expect(body["task_status"] as? String == "todo")
        let raw = String(decoding: data, as: UTF8.self)
        let parsed = try MachineCommand(json: raw, expectedConnectionEpochId: "epoch")
        #expect(parsed.json == raw)
        #expect(parsed.connectionEpochId == "epoch")
        #expect(parsed.deliverySequence == 42)
        #expect(throws: ProductionAgentExecutionWire.Error.invalidMessage) {
            try ProductionAgentExecutionWire.delivery(intent, message: input, sequence: 43)
        }
        var foreign = message
        foreign["channel_id"] = "other-server-channel"
        let invalid = try JSONSerialization.data(withJSONObject: foreign)
        #expect(throws: ProductionAgentExecutionWire.Error.invalidMessage) {
            try ProductionAgentExecutionWire.delivery(intent, message: invalid, sequence: 42)
        }
        var booleanSequence = message
        booleanSequence["seq"] = true
        let invalidSequence = try JSONSerialization.data(withJSONObject: booleanSequence)
        #expect(throws: ProductionAgentExecutionWire.Error.invalidMessage) {
            try ProductionAgentExecutionWire.delivery(intent, message: invalidSequence, sequence: 42)
        }
    }
}
