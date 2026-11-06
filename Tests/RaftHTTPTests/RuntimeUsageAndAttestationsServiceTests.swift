import Foundation
import TestSupport
import Testing

@testable import RaftHTTP

/// Locks the typed runtime-usage/attestation service: the published bodies keep
/// the archive's member order and escaping (which `JSONEncoder` cannot do on
/// Linux), the legacy diagnostic parsers keep their value quirks, and the
/// system-attention receipt decision plus write share one store critical
/// section.

private let fixedNow = Date(timeIntervalSince1970: 1_760_169_600)
private let incidentAt = Date(timeIntervalSince1970: 1_760_166_000)
private let ownerId = "11111111-1111-4111-8111-111111111701"
private let serverId = "33333333-3333-4333-8333-333333333701"

private func makeDirectory() -> EmailLoginDirectory {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: ownerId, email: "runtime-usage-unit@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "runtime-usage-unit", name: "Runtime Usage", ownerId: ownerId)
    return accounts
}

private func makeService(_ accounts: EmailLoginDirectory) -> RuntimeUsageAndAttestationsService {
    RuntimeUsageAndAttestationsService(
        machines: accounts.machinesAndComputersStore,
        messages: accounts.messagesAndThreadsStore,
        channels: accounts.serversAndChannelsStore,
        agents: accounts.agentsRuntimeStore,
        oauth: accounts.oauth,
        sessionUserId: { accounts.sessionUserId(authorization: $0) },
        channelAccess: { _, _, _ in true },
        now: { fixedNow },
        makeArtifactId: { "0f0e0d0c-0b0a-4908-8706-050403020100" }
    )
}

@Test func serverUsageBodyKeepsArchiveMemberOrder() throws {
    let accounts = makeDirectory()
    _ = accounts.oauth.createAgent(serverId: serverId, name: "usage-agent-one")
    _ = accounts.oauth.createAgent(serverId: serverId, name: "usage-agent-two")
    _ = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "usage-machine")
    _ = accounts.oauth.createChannel(serverId: serverId, name: "public", creatorUserId: ownerId)
    _ = accounts.oauth.createChannel(serverId: serverId, name: "private", creatorUserId: ownerId, type: "private")
    _ = accounts.oauth.createChannel(serverId: serverId, name: "thread", creatorUserId: ownerId, type: "thread")

    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    let dto = try makeService(accounts).serverUsage(
        authorization: "Bearer \(token)",
        serverId: serverId
    )
    #expect(dto.jsonBody() == #"{"agents":2,"machines":1,"channels":2}"#)
}

@Test func systemNotificationsBodyIsByteExact() throws {
    let accounts = makeDirectory()
    let firstMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "Alpha Daemon")
    let secondMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "Beta Daemon")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "offline-agent")
    accounts.addServerAgent(serverId: serverId, id: agent, name: "offline-agent", avatarUrl: nil, status: "active")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: firstMachine)

    let sorted = [(id: firstMachine, name: "Alpha Daemon"), (id: secondMachine, name: "Beta Daemon")]
        .sorted { $0.id < $1.id }
    let ids = sorted.map(\.id).joined(separator: ",")
    let names = sorted.map(\.name).joined(separator: ", ")
    let machineRefs = sorted
        .map { #"{"id":"\#($0.id)","name":"\#($0.name)"}"# }
        .joined(separator: ",")

    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    let body = try makeService(accounts).serverSystemNotifications(
        authorization: "Bearer \(token)",
        serverId: serverId
    ).jsonBody()

    #expect(body == #"""
    {"contractVersion":"server-system-notifications-v1","generatedAt":"2025-10-11T08:00:00.000Z","snapshotMode":"replace","clientState":{"read":"none","dismiss":"local_by_notification_id"},"notifications":[{"id":"machine-offline:\#(ids)","type":"machine.offline","schemaVersion":1,"state":"active","kind":"error","title":"\#(names) are offline","body":"1 agent is active on these computers and can't run until they reconnect.","copy":{"titleKey":"machine.offline.title.many","bodyKey":"machine.offline.body.active.many","actionLabelKey":"common.view","params":{"machineNames":"\#(names)","machineCount":2,"activeAgentCount":1,"targetDaemonVersion":null}},"action":{"label":"View","targetType":"machine","targetId":"\#(sorted[0].id)"},"payload":{"machines":[\#(machineRefs)],"activeAgentCount":1,"targetDaemonVersion":null,"evaluation":{"clock":"server","evaluatedAt":"2025-10-11T08:00:00.000Z","offlineAfterMs":0,"statusAuthority":"canonical_machine_read_model","runKind":"raw_daemon","versionAuthority":"latest_daemon_release"}}}]}
    """#)
}

@Test func systemAttentionBodyIsByteExactAndReceiptWriteIsOneCriticalSection() throws {
    let accounts = makeDirectory()
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "Attention Daemon")
    accounts.enableUsageLimitAttentionForServer(serverId)
    let incident = accounts.addSystemAttentionIncidentForTesting(
        serverId: serverId,
        machineId: machine,
        affectedAgentIds: ["agent-a", "agent-b"],
        activatedAt: incidentAt
    )

    let service = makeService(accounts)
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    let body = try service.listSystemAttention(
        authorization: "Bearer \(token)",
        serverId: serverId
    ).jsonBody()

    #expect(body == #"""
    {"contractVersion":"server-system-attention-v1","generatedAt":"2025-10-11T08:00:00.000Z","snapshotMode":"replace","unseenCount":1,"notifications":[{"id":"\#(incident)","kind":"usage_limit_reached","severity":"warning","state":"active","activatedAt":"2025-10-11T07:00:00.000Z","lastObservedAt":"2025-10-11T07:00:00.000Z","seenAt":null,"machine":{"id":"\#(machine)","name":"Attention Daemon"},"provider":"codex","windowKey":"primary","resetsAt":null,"affectedAgentIds":["agent-a","agent-b"]}]}
    """#)

    // The decision and the write are one store critical section: a disabled
    // feed refuses without creating a receipt row.
    let store = accounts.messagesAndThreadsStore
    let key = "\(incident)\n\(ownerId)"
    #expect(store.recordSystemAttentionReceipt(
        serverId: serverId,
        incidentId: incident,
        userId: ownerId,
        attentionEnabled: false,
        dismiss: true,
        now: fixedNow
    ) == false)
    #expect(store.systemAttentionReceipts[key] == nil)

    #expect(store.recordSystemAttentionReceipt(
        serverId: serverId,
        incidentId: incident,
        userId: ownerId,
        attentionEnabled: true,
        dismiss: false,
        now: fixedNow
    ))
    let seenRows = store.systemAttentionNotifications(serverId: serverId, userId: ownerId)
    #expect(seenRows.count == 1)
    #expect(seenRows.first?.seenAt == fixedNow)

    #expect(store.recordSystemAttentionReceipt(
        serverId: serverId,
        incidentId: incident,
        userId: ownerId,
        attentionEnabled: true,
        dismiss: true,
        now: fixedNow
    ))
    #expect(store.systemAttentionNotifications(serverId: serverId, userId: ownerId).isEmpty)
}

@Test func mentionRedriveKeepsTheLegacyVersionParser() throws {
    let accounts = makeDirectory()
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "Redrive Daemon")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "redrive-agent")
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    let service = makeService(accounts)
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    let messageId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    func redrive(_ body: String) throws -> RuntimeStatusDTO {
        try service.redriveMentionDelivery(
            authorization: "Bearer \(token)",
            serverId: serverId,
            machineId: machine,
            agentId: agent,
            messageId: messageId,
            body: body
        )
    }

    // `NSNumber` accepted booleans and integral doubles, so the typed parser
    // must accept the same spellings instead of publishing INVALID_REQUEST.
    for body in [#"{"expectedVersion":0}"#, #"{"expectedVersion":1.0}"#, #"{"expectedVersion":true}"#] {
        #expect(try redrive(body).jsonBody() == #"{"status":"NOT_JOINABLE"}"#)
    }
    for body in [#"{"expectedVersion":-1}"#, #"{"expectedVersion":1,"extra":2}"#, #"{"expectedVersion":"1"}"#, "{}"] {
        #expect(throws: RuntimeUsageAndAttestationsError.invalidRequest) {
            try redrive(body)
        }
    }
}

@Test func transcriptFeedbackKeepsTheLegacyTimestampParser() throws {
    let accounts = makeDirectory()
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "feedback-agent")
    let service = makeService(accounts)
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    let reportId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    func submit(_ body: String) throws -> TranscriptFeedbackAcceptedDTO {
        try service.submitTranscriptFeedback(
            authorization: "Bearer \(token)",
            serverId: serverId,
            agentId: agent,
            reportId: reportId,
            body: body
        )
    }

    #expect(try submit("").jsonBody() == #"{"accepted":true,"feedbackReportId":"\#(reportId)","agentId":"\#(agent)"}"#)
    #expect(try submit(#"{"reportGeneratedAt":null}"#).accepted)
    #expect(try submit(#"{"reportGeneratedAt":"2026-07-20T16:40:04.797Z"}"#).accepted)
    #expect(try submit(#"{"reportGeneratedAt":"2026-07-20T16:40:04Z"}"#).accepted)
    #expect(throws: RuntimeUsageAndAttestationsError.invalidTranscriptRequest) {
        try submit("not-json")
    }
    #expect(throws: RuntimeUsageAndAttestationsError.invalidReportGeneratedAt) {
        try submit(#"{"reportGeneratedAt":"not-a-timestamp"}"#)
    }
    #expect(throws: RuntimeUsageAndAttestationsError.invalidReportGeneratedAt) {
        try submit(#"{"reportGeneratedAt":5}"#)
    }
}
