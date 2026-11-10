import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RaftShared
import TestSupport
import Testing
@testable import RaftHTTP

private let workspaceScanPGEnabled = ProcessInfo.processInfo.environment["RAFT_MACHINE_QUERY_PG_ACCEPTANCE"] == "1"

private struct ScanHTTPReply: Sendable {
    let status: Int
    let body: Data
    let headers: [String: String]
}

/// A real local HTTP client whose deadline outlives the production 15s RPC.
private func scanHTTP(_ f: AgentExecutionPostgresFixture, method: String = "GET", path: String,
    token: String) async throws -> ScanHTTPReply {
    guard path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: path, relativeTo: f.baseURL),
          url.host == "127.0.0.1", url.port == f.baseURL.port else { throw ProtocolPGFailure.invalidResponse }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 30
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(f.serverId, forHTTPHeaderField: "X-Server-Id")
    let (body, raw) = try await session.data(for: request)
    guard let response = raw as? HTTPURLResponse, response.url?.host == "127.0.0.1",
          body.count <= 2 * 1024 * 1024 else { throw ProtocolPGFailure.invalidResponse }
    var headers: [String: String] = [:]
    for name in ["Content-Type", "Content-Length", "Cache-Control", "X-Robots-Tag", "X-Slock-Error-Id"] {
        if let value = response.value(forHTTPHeaderField: name) { headers[name.lowercased()] = value }
    }
    return .init(status: response.statusCode, body: body, headers: headers)
}

private func expectScanFailure(_ reply: ScanHTTPReply) throws {
    #expect(reply.status == 500)
    let body = try ProtocolPGObject(data: reply.body)
    #expect(body.string("error") == "Failed to scan workspaces")
    #expect(body.string("code") == "machine_workspace_scan_failed")
    let correlation = try body.requireString("correlationId")
    #expect(UUID(uuidString: correlation) != nil)
    #expect(reply.headers["x-slock-error-id"] == correlation)
    #expect(Set(body.fields.keys) == Set(["error", "code", "correlationId"]))
}

/// Actual Root/PG/HTTP/NIO transport with a controlled protocol peer. This does
/// not prove an official Computer filesystem scan or any provider execution.
@Test(.enabled(if: workspaceScanPGEnabled), .serialized, .timeLimit(.minutes(2)))
func postgresMachineWorkspaceScanUsesObservedMetadataAndCurrentAuthority() async throws {
    guard let url = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"], !url.isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: url)
    var machine: ControlledMachineProtocolPeer?
    do {
        let owner = try await f.login(f.ownerEmail)
        let member = try await f.login(f.memberEmail)
        let ownerMe = try await f.http("GET", "/api/auth/me", token: owner)
        let memberMe = try await f.http("GET", "/api/auth/me", token: member)
        let ownerId = try ownerMe.object().requireString("id")
        let memberId = try memberMe.object().requireString("id")
        let attached = try await f.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Workspace scan protocol peer")]))
        #expect(attached.status == 201)
        let machineId = try attached.object().requireString("machineId")
        let key = try attached.object().requireString("apiKey")
        let ids = try await f.runtime.execute {
            // These are real retained identity/status fixtures, not daemon scan
            // callbacks. No agent process or provider is started by this test.
            let live = f.accounts.oauth.createAgent(serverId: f.serverId, name: "own-live", displayName: "Live display")
            let stopped = f.accounts.oauth.createAgent(serverId: f.serverId, name: "own-unbound")
            let deleted = f.accounts.oauth.createAgent(serverId: f.serverId, name: "own-deleted")
            for (id, name, status) in [(live, "own-live", "active"), (stopped, "own-unbound", "inactive"), (deleted, "own-deleted", "inactive")] {
                f.accounts.addServerAgent(serverId: f.serverId, id: id, name: name, avatarUrl: nil, status: status)
                f.accounts.oauth.setAgentStatus(id: id, status: status)
            }
            f.accounts.setAgentMachineForTesting(agentId: live, machineId: machineId)
            f.accounts.setAgentMachineForTesting(agentId: deleted, machineId: machineId)
            f.accounts.oauth.deleteAgent(id: deleted)
            let otherServer = UUID().uuidString.lowercased()
            f.accounts.oauth.addOwnedServer(id: otherServer, slug: "workspace-other-\(otherServer)", name: "Other tenant", ownerId: ownerId)
            let foreign = f.accounts.oauth.createAgent(serverId: otherServer, name: "foreign-agent")
            f.accounts.addServerAgent(serverId: otherServer, id: foreign, name: "foreign-agent", avatarUrl: nil, status: "active")
            let otherMachine = f.accounts.registerMachine(serverId: otherServer, userId: ownerId, name: "Foreign machine")
            f.accounts.setAgentMachineForTesting(agentId: foreign, machineId: otherMachine)
            return (live, stopped, deleted, foreign, otherMachine)
        }
        let path = "/api/servers/\(f.serverId)/machines/\(machineId)/workspaces"
        try expectScanFailure(try await scanHTTP(f, path: path, token: owner))
        #expect(try await scanHTTP(f, path: path, token: member).status == 403)
        #expect(try await scanHTTP(f, path: "/api/servers/\(f.serverId)/machines/\(ids.4)/workspaces", token: owner).status == 404)
        var peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key)
        machine = peer
        try await peer.sendControlledReady()
        let modified = "2026-11-09T06:22:33.456Z"
        func directory(_ id: String, size: Int64, count: Int64, display: String? = nil) -> JSONValue {
            var fields: [String: JSONValue] = ["directoryName": .string(id), "totalSizeBytes": .integer(size),
                "lastModified": .string(modified), "fileCount": .integer(count)]
            if let display { fields["displayPath"] = .string(display) }
            return .object(fields)
        }
        let directories: [JSONValue] = [directory(ids.0, size: 1234, count: 3, display: "~/.raft/agents/\(ids.0)/"),
            directory(ids.1, size: 2345, count: 4), directory(ids.2, size: 3456, count: 5),
            directory(ids.3, size: 9999, count: 9), directory(UUID().uuidString.lowercased(), size: 8888, count: 8)]
        let expected: [JSONValue] = [
            .object(["directoryName": .string(ids.0), "totalSizeBytes": .integer(1234), "lastModified": .string(modified),
                "fileCount": .integer(3), "displayPath": .string("~/.raft/agents/\(ids.0)/"), "status": .string("active"),
                "agentName": .string("Live display"), "agentStatus": .string("active")]),
            .object(["directoryName": .string(ids.1), "totalSizeBytes": .integer(2345), "lastModified": .string(modified),
                "fileCount": .integer(4), "status": .string("stopped"), "agentName": .string("own-unbound"), "agentStatus": .string("inactive")]),
            .object(["directoryName": .string(ids.2), "totalSizeBytes": .integer(3456), "lastModified": .string(modified),
                "fileCount": .integer(5), "status": .string("deleted"), "agentName": .string("own-deleted"), "agentStatus": .string("inactive")]),
        ]
        var getLength: String?
        for method in ["GET", "HEAD"] {
            let start = peer.socket.count
            let pending = Task { try await scanHTTP(f, method: method, path: path, token: owner) }
            defer { pending.cancel() }
            let request = try await peer.socket.nextObject(since: start) { $0.string("type") == "machine:workspace:scan" }
            #expect(request.fields == ["type": .string("machine:workspace:scan")])
            // This real ready ingress must COMMIT before the RPC result: the
            // GET and HEAD paths cannot hold the outer BPR writer while waiting.
            try await peer.sendControlledReady()
            if method == "GET" { try expectScanFailure(try await scanHTTP(f, path: path, token: owner)) }
            try await peer.socket.send(.init(["type": .string("machine:workspace:scan_result"), "directories": .array(directories)]))
            let response = try await pending.value
            #expect(response.status == 200)
            #expect(response.headers["cache-control"] == "private, no-store")
            if method == "GET" {
                #expect(try JSONDecoder().decode([JSONValue].self, from: response.body) == expected)
                getLength = response.headers["content-length"]
                #expect(getLength == String(response.body.count))
            } else {
                #expect(response.body.isEmpty)
                #expect(response.headers["content-length"] == getLength)
            }
        }
        // A role change commits while scan is outstanding; the reply cannot
        // preserve stale admin authority. The machine creator is a different user.
        try await f.runtime.execute { f.accounts.oauth.addMember(serverId: f.serverId, userId: memberId, role: "admin") }
        let roleBoundary = peer.socket.count
        let revoked = Task { try await scanHTTP(f, path: path, token: member) }
        defer { revoked.cancel() }
        _ = try await peer.socket.nextObject(since: roleBoundary) { $0.string("type") == "machine:workspace:scan" }
        try await f.runtime.execute { f.accounts.oauth.addMember(serverId: f.serverId, userId: memberId, role: "member") }
        try await peer.socket.send(.init(["type": .string("machine:workspace:scan_result"), "directories": .array(directories)]))
        #expect(try await revoked.value.status == 403)
        // Missing required filesystem metadata is an error, never invented zeros.
        let malformedBoundary = peer.socket.count
        let malformed = Task { try await scanHTTP(f, path: path, token: owner) }
        defer { malformed.cancel() }
        _ = try await peer.socket.nextObject(since: malformedBoundary) { $0.string("type") == "machine:workspace:scan" }
        try await peer.socket.send(.init(["type": .string("machine:workspace:scan_result"),
            "directories": .array([.object(["directoryName": .string(ids.0)])])]))
        try expectScanFailure(try await malformed.value)
        // Replacing the authenticated connection invalidates an outstanding scan.
        let oldEpochBoundary = peer.socket.count
        let oldEpoch = Task { try await scanHTTP(f, path: path, token: owner) }
        defer { oldEpoch.cancel() }
        _ = try await peer.socket.nextObject(since: oldEpochBoundary) { $0.string("type") == "machine:workspace:scan" }
        let nextEpoch = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key)
        machine = nextEpoch
        try await nextEpoch.sendControlledReady()
        try expectScanFailure(try await oldEpoch.value)
        peer = nextEpoch
        // Exact production timeout, with no injected faster clock or probe.
        let timeoutBoundary = peer.socket.count
        let timeout = Task { try await scanHTTP(f, path: path, token: owner) }
        defer { timeout.cancel() }
        _ = try await peer.socket.nextObject(since: timeoutBoundary) { $0.string("type") == "machine:workspace:scan" }
        try expectScanFailure(try await timeout.value)
        try await peer.socket.send(.init(["type": .string("machine:workspace:scan_result"), "directories": .array(directories)]))
        try await peer.socket.applicationFence()
        let quarantinedBoundary = peer.socket.count
        try expectScanFailure(try await scanHTTP(f, path: path, token: owner))
        let frames = try await peer.socket.wireFence(since: quarantinedBoundary)
        #expect(!frames.contains { (try? ProtocolPGObject(text: $0).string("type")) == "machine:workspace:scan" })
        await peer.socket.close(); machine = nil
        let rebound = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key)
        let sameDaemon = ControlledMachineProtocolPeer(socket: rebound.socket, context: rebound.context, daemonId: peer.daemonId)
        machine = sameDaemon
        try await sameDaemon.sendControlledReady()
        try await sameDaemon.socket.send(.init(["type": .string("machine:workspace:scan_result"), "directories": .array(directories)]))
        try await sameDaemon.socket.applicationFence()
        let sameDaemonBoundary = sameDaemon.socket.count
        try expectScanFailure(try await scanHTTP(f, path: path, token: owner))
        let sameDaemonFrames = try await sameDaemon.socket.wireFence(since: sameDaemonBoundary)
        #expect(!sameDaemonFrames.contains { (try? ProtocolPGObject(text: $0).string("type")) == "machine:workspace:scan" })
        await sameDaemon.socket.close(); machine = nil
        // Only a DIFFERENT real ready daemon-instance ID releases quarantine.
        let replacement = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key)
        machine = replacement
        try await replacement.sendControlledReady()
        let replacementBoundary = replacement.socket.count
        let fresh = Task { try await scanHTTP(f, path: path, token: owner) }
        defer { fresh.cancel() }
        _ = try await replacement.socket.nextObject(since: replacementBoundary) { $0.string("type") == "machine:workspace:scan" }
        try await replacement.socket.send(.init(["type": .string("machine:workspace:scan_result"), "directories": .array([])]))
        let freshResponse = try await fresh.value
        #expect(freshResponse.status == 200 && freshResponse.body == Data("[]".utf8))
        // Cleanup remains explicitly unavailable: no cache/archive tombstone or
        // physical deletion is accepted as success in this bounded read repair.
        let deletionBoundary = replacement.socket.count
        for directory in [ids.0, ids.2] {
            let deletion = try await f.http("DELETE", path + "/" + directory, token: owner)
            #expect(deletion.status == 503)
            #expect(try deletion.object().fields == ["error": .string("Machine workspace deletion is unavailable"),
                "code": .string("machine_workspace_delete_unavailable"), "retryable": .bool(false)])
        }
        #expect(try await f.http("DELETE", path + "/" + ids.3, token: owner).status == 404)
        #expect(try await f.http("DELETE", path + "/" + UUID().uuidString.lowercased(), token: owner).status == 404)
        let deletionFrames = try await replacement.socket.wireFence(since: deletionBoundary)
        #expect(!deletionFrames.contains { (try? ProtocolPGObject(text: $0).string("type")) == "machine:workspace:delete" })
        await f.close(machine: machine); machine = nil
    } catch {
        await f.close(machine: machine)
        throw error
    }
}
