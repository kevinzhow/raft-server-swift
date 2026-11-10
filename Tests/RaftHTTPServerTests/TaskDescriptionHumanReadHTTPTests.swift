import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func humanDescriptionReadObject(_ response: ClientResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
}

/// These are published HTTP assertions. The external reader has a real server-minted
/// agent credential; no runtime, process, ready frame or provider is involved.
private func runHumanDescriptionReadScenario(humanReads: Bool) async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = UUID().uuidString.lowercased()
    let outsiderId = UUID().uuidString.lowercased()
    let serverId = UUID().uuidString.lowercased()
    let suffix = String(UUID().uuidString.prefix(8)).lowercased()
    for (id, name) in [(ownerId, "description-owner"), (outsiderId, "description-outsider")] {
        accounts.addAccount(id: id, email: "\(name)-\(suffix)@slock.test", password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "description-\(suffix)", name: "Description", ownerId: ownerId)
    let ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
    let outsiderToken = accounts.mintAccessTokenForTesting(userId: outsiderId)
    let prefix = "Write exactly \"native marker\".\nRead back the file; keep this full description: "
    let description = prefix + String(repeating: "x", count: 290 - prefix.utf8.count)
    #expect(description.utf8.count == 290)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func headers(_ token: String) -> HTTPFields {
                var value = HTTPFields()
                value[.authorization] = "Bearer \(token)"
                value[.contentType] = "application/json"
                value[HTTPField.Name("X-Server-Id")!] = serverId
                return value
            }
            let ownerHeaders = headers(ownerToken)
            func post(_ path: String, _ body: [String: Any]) async throws -> ClientResponse {
                let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                return try await client.send(.post, headers: ownerHeaders, to: URI(string: path)) {
                    $0.body = .init(data: data)
                }
            }

            let channel = try await post("/api/channels", ["name": "description-room"])
            #expect(channel.status == .ok)
            let channelId = try #require(try humanDescriptionReadObject(channel)["id"] as? String)
            let createdAgent = try await post("/api/agents", ["name": "DescriptionReader", "external": true])
            #expect(createdAgent.status == .ok)
            let agentId = try #require(try humanDescriptionReadObject(createdAgent)["id"] as? String)
            let joined = try await post("/api/channels/\(channelId)/members", ["agentId": agentId])
            #expect(joined.status == .ok)
            let credentialReply = try await post("/api/agents/\(agentId)/credentials", [:])
            #expect(credentialReply.status.code == 201)
            let key = try #require(try humanDescriptionReadObject(credentialReply)["apiKey"] as? String)
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(key)"
            let created = try await post("/api/tasks/channel/\(channelId)", ["tasks": [
                ["title": "Title is not the instructions", "description": description],
                ["title": "No description"],
                ["title": "Empty description", "description": ""],
            ]])
            #expect(created.status == .ok)
            let createdTasks = try #require(try humanDescriptionReadObject(created)["tasks"] as? [[String: Any]])
            #expect(createdTasks.count == 3)
            #expect(createdTasks[0]["description"] as? String == description)
            #expect(createdTasks[1]["description"] is NSNull)
            #expect(createdTasks[2]["description"] as? String == "")

            let path = "/internal/agent-api/tasks?channel=%23description-room&status=all"
            let listed = try await client.get(URI(string: path), headers: agentHeaders)
            #expect(listed.status == .ok)
            let rows = try #require(try humanDescriptionReadObject(listed)["tasks"] as? [[String: Any]])
            #expect(rows.count == 3)
            let first = try #require(rows.first { $0["taskNumber"] as? Int == 1 })
            let fullDescription = try #require(first["description"] as? String)
            #expect(Data(fullDescription.utf8) == Data(description.utf8))
            #expect(first["title"] as? String == "Title is not the instructions")
            #expect(rows.first { $0["taskNumber"] as? Int == 2 }?["description"] is NSNull)
            #expect(rows.first { $0["taskNumber"] as? Int == 3 }?["description"] as? String == "")
            // The official `task show` performs exactly this list(status=all),
            // then selects taskNumber. It has no independent detail endpoint.
            let missingAgent = try await client.get(URI(string: path))
            #expect(missingAgent.status == .unauthorized)
            let deniedChannel = try await client.get(URI(string: "/internal/agent-api/tasks?channel=%23not-a-visible-channel"), headers: agentHeaders)
            #expect(deniedChannel.status == .notFound)
            #expect(!(deniedChannel.body.string ?? "").contains(description))

            if humanReads {
                let list = try await client.get(URI(string: "/api/tasks/channel/\(channelId)"), headers: ownerHeaders)
                #expect(list.status == .ok)
                let humanRows = try #require(try humanDescriptionReadObject(list)["tasks"] as? [[String: Any]])
                #expect(humanRows.count == 3)
                let expectedKeys: Set<String> = ["id", "messageId", "channelId", "channelName", "channelType", "taskNumber", "title", "description", "status", "createdByType", "createdById", "createdByName", "createdByMembershipStatus", "claimedByType", "claimedById", "claimedByName", "claimedAt", "completedAt", "requiresResourceReceipt", "resourceReceipt", "resourceReceiptRecordedAt", "resourceTeardownOwnerAgentId", "resourceExpiryFollowupId", "createdAt", "updatedAt", "revision", "taskCurrentProjection", "isLegacy"]
                #expect(humanRows.allSatisfy { Set($0.keys) == expectedKeys })
                for (index, expected) in [(0, description), (2, "")] {
                    #expect(humanRows[index]["description"] as? String == expected)
                    let number = index + 1
                    let detail = try await client.get(URI(string: "/api/tasks/channel/\(channelId)/number/\(number)"), headers: ownerHeaders)
                    #expect(detail.status == .ok)
                    let row = try #require(try humanDescriptionReadObject(detail)["task"] as? [String: Any])
                    #expect(row["description"] as? String == expected)
                }
                #expect(humanRows[1]["description"] is NSNull)
                let nilDetail = try await client.get(URI(string: "/api/tasks/channel/\(channelId)/number/2"), headers: ownerHeaders)
                let nilRow = try #require(try humanDescriptionReadObject(nilDetail)["task"] as? [String: Any])
                #expect(nilRow["description"] is NSNull)
                for route in ["/api/tasks/channel/\(channelId)", "/api/tasks/channel/\(channelId)/number/1"] {
                    #expect(try await client.get(URI(string: route)).status == .unauthorized)
                    let denied = try await client.get(URI(string: route), headers: headers(outsiderToken))
                    #expect(denied.status == .forbidden)
                    #expect(!(denied.body.string ?? "").contains(description))
                }
            }
        }
    }
}

@Test func taskDescriptionHumanReaderListAndNumberPreserveText() async throws {
    try await runHumanDescriptionReadScenario(humanReads: true)
}
