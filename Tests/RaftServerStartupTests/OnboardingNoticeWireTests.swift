import Foundation
import RaftConnectAuth
import RaftHTTP
import RaftMachineSocket
import Testing
@testable import RaftHTTP
@testable import RaftServer

/// Real TCP/WebSocket daemon fixture for the transient onboarding notice.
///
/// It proves the published machine wire, not a service recorder: the official
/// `agent:deliver` frame is written to an authenticated connection, the peer
/// acks it exactly like the official Computer (`ackSeq = 0` for a synthetic
/// notice), and the registry resolves its acknowledgement promise from that
/// real frame.
private struct NoticeWireLookup: MachineCredentialLooking {
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution {
        .linked(computerId: "notice-computer", machineId: "notice-machine")
    }
    func machine(id: String) async throws -> MatchedMachine? {
        .init(id: "notice-machine", serverId: "notice-server")
    }
    func serverExists(id: String) async throws -> Bool { true }
    func machine(apiKey: String) async throws -> MatchedMachine? { nil }
}

private func noticeCommand() throws -> AgentExecutionCommand {
    let body: [String: Any] = [
        "commandId": "11111111-1111-4111-8111-111111111851", "kind": "notice",
        "serverId": "notice-server", "machineId": "notice-machine", "agentId": "notice-agent",
        "launchId": "notice-launch", "deliveryId": "notice-delivery", "connectionEpochId": "epoch",
        "takeoverEpoch": 1, "breakerGeneration": 1, "humanStart": false,
        "channelId": "onboarding-context", "messageId": "onboarding-owner-facts-notice-server",
        "status": "pending", "createdAt": 0,
        "notice": ["channelName": "onboarding-context", "channelType": "channel",
                   "content": "Onboarding context for this server",
                   "timestamp": "2026-01-01T00:00:00.000Z"],
    ]
    return try JSONDecoder().decode(AgentExecutionCommand.self,
                                    from: JSONSerialization.data(withJSONObject: body))
}

@Test func transientNoticeReachesTheDaemonAsASeqZeroDeliveryAndIsAcknowledged() async throws {
    let registry = MachineCommandRegistry(durableIngress: MachineDurableIngress(
        onOpened: { _ in },
        onMessage: { _, message in
            switch message.type {
            case "ready", "agent:deliver:ack": return .committed(ack: nil)
            default: return .hold(reason: "unexpected_frame")
            }
        },
        onClosed: { _ in }
    ))
    let server = try await MachineConnectServer.start(lookup: NoticeWireLookup(), commandRegistry: registry)
    do {
        let peer = try await ControlledMachineProtocolPeer.connect(port: server.port,
                                                                    key: "sk_computer_notice_wire")
        do {
            let epoch = try peer.context.requireString("connectionEpochId")
            try await peer.sendControlledReady()
            let command = try noticeCommand()
            let body: [String: Any] = [
                "channel_id": "onboarding-context", "channel_name": "onboarding-context",
                "channel_type": "channel", "message_id": "onboarding-owner-facts-notice-server",
                "sender_id": "system", "sender_name": "system", "sender_type": "system",
                "content": "Onboarding context for this server",
                "timestamp": "2026-01-01T00:00:00.000Z",
            ]
            let message = try JSONSerialization.data(withJSONObject: body)
            let data = try ProductionAgentExecutionWire.notice(command, message: message)
            let wire = try MachineCommand(json: String(decoding: data, as: UTF8.self),
                                          expectedConnectionEpochId: epoch)
            #expect(wire.deliverySequence == 0)
            let boundary = peer.socket.count
            let sent = Task {
                try await registry.sendAndAwaitAcknowledgement(
                    machineId: "notice-machine", command: wire,
                    timeout: .seconds(5), requiredRuntime: "codex"
                )
            }
            let frame = try await peer.socket.nextObject(since: boundary) {
                $0.string("type") == "agent:deliver"
            }
            #expect(frame.string("agentId") == "notice-agent")
            #expect(frame.integer("seq") == 0)
            #expect(frame.string("deliveryId") == "notice-delivery")
            let messageObject = try #require(frame.object("message"))
            #expect(messageObject.string("message_id") == "onboarding-owner-facts-notice-server")
            #expect(messageObject.string("sender_type") == "system")
            #expect(messageObject.string("channel_id") == "onboarding-context")
            #expect(messageObject.integer("seq") == nil)
            // The official Computer acks with the resolved seq (0 here).
            try await peer.acknowledgeControlledDelivery(frame)
            let reply = try await sent.value
            #expect(reply.stage == .acknowledgement)
            #expect(reply.commandId == "notice-delivery")
            try await peer.socket.close()
        } catch {
            try? await peer.socket.close()
            throw error
        }
    } catch {
        try? await server.close()
        throw error
    }
    try await server.close()
}
