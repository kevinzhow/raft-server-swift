import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The parsed-query side of `GET /internal/agent-api/tasks/history`.
///
/// Pinned `routes/internalAgentApi.ts:475-486` replaces `req.query` with the
/// schema's `parsed.data` before the handler, so the task lookup consumes the
/// trimmed `channel` and the `z.coerce.number().int().positive()` result — not
/// the raw query string. These assertions read the actual task-history response
/// for each accepted JavaScript `Number(string)` form, so a route that merely
/// passes validation but looks up task 0 cannot satisfy them.
@Test func agentApiContractTaskHistoryUsesParsedQueryValues() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001030001"
    let ownerId = "11111111-1111-4111-8111-000001030001"
    accounts.addAccount(id: ownerId, email: "agent-history-parsed@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-history-parsed", name: "Agent History Parsed", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "all", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "all")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "HistoryParseBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send", "tasks"], name: "parse")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func object(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            let channelRef = "#all"

            // Task numbers are channel-sequential: seed 1...16 so the accepted
            // query forms below resolve to a task with a distinctive title.
            let titles = (1...16).map { String(format: "history-%02d", $0) }
            let tasksJSON = titles.map { #"{"title":"\#($0)"}"# }.joined(separator: ",")
            let created = try await client.send(
                .post, headers: headers, to: "/internal/agent-api/tasks"
            ) { request in
                request.body = .init(string: #"{"channel":"\#(channelRef)","tasks":[\#(tasksJSON)]}"#)
            }
            #expect(created.status == .ok)
            let createdTasks = object(created)["tasks"] as? [[String: Any]] ?? []
            #expect(createdTasks.count == titles.count)
            for (index, row) in createdTasks.enumerated() {
                #expect(row["taskNumber"] as? Int == index + 1)
                #expect(row["title"] as? String == titles[index])
            }

            func history(_ query: String) async throws -> ClientResponse {
                try await client.send(
                    .get, headers: headers,
                    to: URI(string: "/internal/agent-api/tasks/history?\(query)")
                )
            }
            func historyTask(_ response: ClientResponse) -> [String: Any] {
                object(response)["task"] as? [String: Any] ?? [:]
            }

            // Every form below is finite and positive to `Number(string)`:
            // binary, octal, exponent, decimal with surrounding whitespace, and
            // hex. The response must name the matching seeded task.
            let accepted: [(raw: String, taskNumber: Int)] = [
                ("0b101", 5),
                ("0o17", 15),
                ("1e1", 10),
                ("%2010.0%20", 10),
                ("0x10", 16),
            ]
            for (raw, taskNumber) in accepted {
                let response = try await history("channel=%23all&task_number=\(raw)")
                #expect(response.status == .ok, "task_number=\(raw)")
                let task = historyTask(response)
                #expect(task["taskNumber"] as? Int == taskNumber, "task_number=\(raw)")
                #expect(task["title"] as? String == titles[taskNumber - 1], "task_number=\(raw)")
                let events = object(response)["events"] as? [[String: Any]] ?? []
                #expect(events.isEmpty == false, "task_number=\(raw)")
            }

            // The schema trims `channel`, and the middleware writes the parsed
            // value back; the padded form must select the same channel target.
            let paddedChannel = try await history("channel=%20%23all%20&task_number=5")
            #expect(paddedChannel.status == .ok)
            #expect(historyTask(paddedChannel)["taskNumber"] as? Int == 5)

            // Express turns repeated keys into arrays. `Number(["5","6"])` is
            // `Number("5,6")` = NaN, so a duplicate task_number is a contract
            // rejection rather than first/last-wins.
            let duplicateNumber = try await history(
                "channel=%23all&task_number=5&task_number=6"
            )
            #expect(duplicateNumber.status == .badRequest)
            #expect(object(duplicateNumber)["code"] as? String == "agent_api_contract_invalid")
            let numberIssues = object(duplicateNumber)["issues"] as? [[String: Any]] ?? []
            #expect(numberIssues.count == 1)
            #expect(numberIssues.first?["path"] as? String == "task_number")
            #expect(numberIssues.first?["message"] as? String == "Invalid input: expected number, received NaN")

            // A repeated string member is an array, which the string schema
            // reports before the surviving task_number parses.
            let duplicateChannel = try await history(
                "channel=%23all&channel=%23all&task_number=5"
            )
            #expect(duplicateChannel.status == .badRequest)
            #expect(object(duplicateChannel)["code"] as? String == "agent_api_contract_invalid")
            let channelIssues = object(duplicateChannel)["issues"] as? [[String: Any]] ?? []
            #expect(channelIssues.count == 1)
            #expect(channelIssues.first?["path"] as? String == "channel")
            #expect(channelIssues.first?["message"] as? String == "Invalid input: expected string, received array")
        }
    }
}
