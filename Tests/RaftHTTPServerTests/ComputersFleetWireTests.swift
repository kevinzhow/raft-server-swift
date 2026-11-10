import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Byte-exact wire locks for the fleet routes that now answer through the
/// canonical `respond`: member order, status and header set.

private let wireOwner = "11111111-1111-4111-8111-111111111821"
private let wireServer = "33333333-3333-4333-8333-333333333821"

@Test func computersFleetRoutesPublishTheLegacyBytes() async throws {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: wireOwner, email: "fleet-wire@slock.test", password: "password123")
    accounts.markEmailVerified(userId: wireOwner)
    accounts.oauth.addOwnedServer(id: wireServer, slug: "fleet-wire", name: "Fleet Wire", ownerId: wireOwner)
    let ghostCreator = "11111111-1111-4111-8111-111111111899"
    let machineId = accounts.registerMachine(serverId: wireServer, userId: ghostCreator, name: "ghost-box")
    let token = accounts.mintAccessTokenForTesting(userId: wireOwner)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var json = HTTPFields()
            json[.authorization] = "Bearer \(token)"
            json[.contentType] = "application/json"
            var bare = HTTPFields()
            bare[.authorization] = "Bearer \(token)"

            let list = try await client.send(.get, headers: json, to: "/api/servers/\(wireServer)/machines")
            #expect(list.status == .ok)
            #expect(list.body.string == #"{"machines":[{"id":"\#(machineId)","name":"ghost-box","userId":"\#(ghostCreator)","description":null,"isComputer":false,"computerAttachedByCurrentUser":false,"agentCount":0,"creator":null,"status":"offline","statusVersion":0,"runtimes":[],"runtimeVersions":{},"runtimeDetection":null,"hostname":null,"lastHeartbeat":null,"computerUpgradeAvailable":null,"computerBroadcastPolicy":null}],"latestComputerVersion":null,"latestComputerReleaseNotes":null}"#)
            #expect(list.headers[.contentType] == "application/json; charset=utf-8" || list.headers[.contentType] != nil)
            #expect(list.headers[HTTPField.Name("X-Robots-Tag")!] != nil)

            // A legacy Bool cannot grant real connection presence. The published
            // logical version must still be the actual existing owner counter.
            accounts.setMachineOnline(machineId: machineId, online: true)
            let bumped = accounts.bumpMachineStatusVersion(machineId: machineId)
            let legacy = try await client.send(.get, headers: json, to: "/api/servers/\(wireServer)/machines")
            #expect(legacy.status == .ok)
            let legacyBody = try JSONSerialization.jsonObject(with: Data((legacy.body.string ?? "").utf8)) as? [String: Any]
            let row = try #require((legacyBody?["machines"] as? [[String: Any]])?.first)
            #expect(row["status"] as? String == "offline")
            #expect(row["statusVersion"] as? Int == bumped)
            #expect(row["hostname"] is NSNull)
            #expect(row["lastHeartbeat"] is NSNull)

            // A body without a JSON Content-Type is still read (the legacy raw parse).
            let patched = try await client.send(.patch, headers: bare, to: "/api/servers/\(wireServer)/machines/\(machineId)") { request in
                request.body = .init(string: #"{"description":" hi "}"#)
            }
            #expect(patched.status == .ok)
            #expect(patched.body.string == #"{"id":"\#(machineId)","name":"ghost-box","description":"hi"}"#)

            let missing = try await client.send(.patch, headers: json, to: "/api/servers/\(wireServer)/machines/nope") { request in
                request.body = .init(string: "{}")
            }
            #expect(missing.status == .notFound)
            #expect(missing.body.string == #"{"error":"Machine not found"}"#)

            let attach = try await client.send(.post, headers: json, to: "/api/computer/attach") { request in
                request.body = .init(string: #"{"serverSlug":"fleet-wire","name":"wire-computer"}"#)
            }
            #expect(attach.status == .created)
            let parsed = try JSONSerialization.jsonObject(with: Data((attach.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let apiKey = parsed["apiKey"] as? String ?? ""
            let attachedMachine = parsed["machineId"] as? String ?? ""
            let computerId = parsed["serverMachineId"] as? String ?? ""
            #expect(attach.body.string == #"{"apiKey":"\#(apiKey)","serverMachineId":"\#(computerId)","machineId":"\#(attachedMachine)","serverId":"\#(wireServer)","serverSlug":"fleet-wire","name":"wire-computer","resumed":false}"#)

            let collision = try await client.send(.post, headers: json, to: "/api/computer/attach") { request in
                request.body = .init(string: #"{"serverSlug":"fleet-wire","name":"wire-computer"}"#)
            }
            #expect(collision.status == .conflict)
            #expect(collision.body.string == #"{"error":"A Computer with this name already exists","code":"COMPUTER_NAME_COLLISION"}"#)

            let opId = UUID().uuidString.lowercased()
            let parentId = UUID().uuidString.lowercased()
            let lifecycleBody = #"{"action":"start","operationId":"\#(opId)","parentOperationId":"\#(parentId)"}"#
            let lifecycle = try await client.send(.post, headers: json, to: "/api/servers/\(wireServer)/machines/\(attachedMachine)/computer-lifecycle-operations") { request in
                request.body = .init(string: lifecycleBody)
            }
            #expect(lifecycle.status == .created)
            #expect(lifecycle.body.string == #"{"operationId":"\#(opId)","parentOperationId":"\#(parentId)","serverId":"\#(wireServer)","machineId":"\#(attachedMachine)","actorUserId":"\#(wireOwner)","action":"start","dispatchMode":"local","connectionEpochBefore":null,"targetVersion":null}"#)

            accounts.setRemoteUpgradeGateForTesting(serverId: wireServer, enabled: false)
            let upgradeBody = #"{"action":"upgrade","operationId":"\#(opId)","parentOperationId":"\#(parentId)"}"#
            let gated = try await client.send(.post, headers: json, to: "/api/servers/\(wireServer)/machines/\(attachedMachine)/computer-lifecycle-operations") { request in
                request.body = .init(string: upgradeBody)
            }
            #expect(gated.status == .conflict)
            #expect(gated.body.string == #"{"error":"Hands could not select a newer alpha release for this Computer.","code":"broadcast_disabled","policy":{"eligibility":"no_broadcast","reasonCode":"broadcast_disabled"}}"#)

            var computerHeaders = HTTPFields()
            computerHeaders[.authorization] = "Bearer \(apiKey)"
            let runners = try await client.send(.get, headers: computerHeaders, to: "/internal/computer/runners")
            #expect(runners.status == .ok)
            #expect(runners.body.string == #"{"whitelist":["agentId","name","status","model","runtime"],"runners":[]}"#)
            let denied = try await client.send(.get, headers: bare, to: "/internal/computer/runners")
            #expect(denied.status == .unauthorized)
            #expect(denied.body.string == #"{"error":"Invalid computer credential"}"#)

            let rescan = try await client.send(.post, headers: json, to: "/api/servers/\(wireServer)/machines/\(attachedMachine)/runtimes/rescan")
            #expect(rescan.status == .conflict)
            #expect(rescan.body.string == #"{"error":"Computer is offline"}"#)

            let removed = try await client.send(.delete, headers: json, to: "/api/servers/\(wireServer)/machines/\(attachedMachine)")
            #expect(removed.status == .ok)
            #expect(removed.body.string == #"{"ok":true}"#)
        }
    }
}
