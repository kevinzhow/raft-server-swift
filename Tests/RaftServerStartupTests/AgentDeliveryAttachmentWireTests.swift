import Foundation
import RaftConnectAuth
import RaftHTTP
import RaftMachineSocket
import RaftShared
import Testing
@testable import RaftHTTP
@testable import RaftServer

/// The real machine WebSocket frame is the published agent deliver surface.
/// It must carry the attachment envelope the CLI renders (`id`, `filename`,
/// `mimeType`, `sizeBytes`) and the retained human handle, not a pre-profile
/// placeholder.
private struct AttachmentWireLookup: MachineCredentialLooking {
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution {
        .linked(computerId: "attachment-computer", machineId: "attachment-machine")
    }
    func machine(id: String) async throws -> MatchedMachine? {
        .init(id: "attachment-machine", serverId: "attachment-server")
    }
    func serverExists(id: String) async throws -> Bool { true }
    func machine(apiKey: String) async throws -> MatchedMachine? { nil }
}

private func attachmentDeliveryCommand() throws -> AgentExecutionCommand {
    let body: [String: Any] = [
        "commandId": "11111111-1111-4111-8111-111111111861", "kind": "delivery",
        "serverId": "attachment-server", "machineId": "attachment-machine",
        "agentId": "attachment-agent", "launchId": "attachment-launch",
        "deliveryId": "attachment-delivery", "connectionEpochId": "epoch",
        "takeoverEpoch": 1, "breakerGeneration": 1, "humanStart": false,
        "channelId": "attachment-channel", "messageId": "attachment-message",
        "status": "pending", "createdAt": 0,
    ]
    return try JSONDecoder().decode(AgentExecutionCommand.self,
                                    from: JSONSerialization.data(withJSONObject: body))
}

@Test func agentDeliveryFrameCarriesAttachmentMetadataAndRetainedHandle() async throws {
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
    let server = try await MachineConnectServer.start(lookup: AttachmentWireLookup(), commandRegistry: registry)
    do {
        let peer = try await ControlledMachineProtocolPeer.connect(
            port: server.port, key: "sk_computer_attachment_wire")
        do {
            let epoch = try peer.context.requireString("connectionEpochId")
            try await peer.sendControlledReady()
            let command = try attachmentDeliveryCommand()
            let message = StoredHumanMessage(
                id: "attachment-message", channelId: "attachment-channel",
                senderId: "attachment-owner", content: "please read acceptance.txt",
                seq: 7, attachmentIds: ["attachment-file"])
            let attachment = ChannelAttachment(
                id: "attachment-file", channelId: "attachment-channel",
                uploaderId: "attachment-owner", filename: "acceptance.txt",
                messageId: "attachment-message", messagePosition: 0,
                mimeType: "text/plain", sizeBytes: 130, uploaderType: "user")
            let delivery = MaterializedAgentDelivery(
                message: message, localChannelId: "attachment-channel",
                channelName: "all", channelType: "channel",
                senderName: "kevinchou-c", senderDescription: nil,
                recipientId: "attachment-agent", task: nil,
                taskAssigneeName: nil, attachments: [attachment], parent: nil)
            let data = try delivery.encoded()
            let wire = try MachineCommand(
                json: String(decoding: ProductionAgentExecutionWire.delivery(
                    command, message: data, sequence: 7), as: UTF8.self),
                expectedConnectionEpochId: epoch)
            let boundary = peer.socket.count
            let sent = Task {
                try await registry.sendAndAwaitAcknowledgement(
                    machineId: "attachment-machine", command: wire,
                    timeout: .seconds(5), requiredRuntime: "codex"
                )
            }
            let frame = try await peer.socket.nextObject(since: boundary) {
                $0.string("type") == "agent:deliver"
            }
            let messageObject = try #require(frame.object("message"))
            #expect(messageObject.string("sender_name") == "kevinchou-c")
            let attachments = try #require(messageObject.array("attachments"))
            #expect(attachments.count == 1)
            guard case .object(let attachmentObject) = attachments[0] else {
                Issue.record("Expected one attachment object")
                return
            }
            #expect(attachmentObject["id"] == .string("attachment-file"))
            #expect(attachmentObject["filename"] == .string("acceptance.txt"))
            #expect(attachmentObject["mimeType"] == .string("text/plain"))
            #expect(attachmentObject["sizeBytes"] == .integer(130))
            try await peer.acknowledgeControlledDelivery(frame)
            let reply = try await sent.value
            #expect(reply.stage == .acknowledgement)
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
