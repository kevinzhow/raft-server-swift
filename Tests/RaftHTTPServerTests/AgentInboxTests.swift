import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func inboxObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func agentInboxDrainsThirdPartyEventsAndClearsWakeHints() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111227"
    let serverId = "33333333-3333-4333-8333-333333333421"
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-inbox-227", name: "Agent Inbox", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "InboxBot")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Inbox Event Client",
        clientId: "agent-inbox-227",
        allowedScopes: ["openid", "agent:event:write"]
    )
    let apiKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "inbox-test")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var jsonHeaders = HTTPFields()
            jsonHeaders[.contentType] = "application/json"
            let requested = try await client.send(.post, headers: jsonHeaders, to: "/api/oauth/requests/agent") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"agent-inbox-227\",\"agentName\":\"InboxBot\",\"scopes\":[\"agent:event:write\"]}")
            }
            let requestId = try inboxObject(requested)["requestId"] as? String ?? ""
            let tokenBody: [String: Any] = [
                "clientId": created.clientId,
                "clientSecret": created.clientSecret,
                "grantType": "urn:slock:grant-type:agent_request",
                "requestId": requestId,
                "resource": "urn:raft:server:\(serverId):agent-inbound",
            ]
            let tokenData = try JSONSerialization.data(withJSONObject: tokenBody)
            let exchanged = try await client.send(.post, headers: jsonHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: String(decoding: tokenData, as: UTF8.self))
            }
            let accessToken = try inboxObject(exchanged)["access_token"] as? String ?? ""

            var eventHeaders = HTTPFields()
            eventHeaders[.contentType] = "application/json"
            eventHeaders[.authorization] = "Bearer \(accessToken)"
            let posted = try await client.send(.post, headers: eventHeaders, to: "/api/oauth/agent-events") { request in
                request.body = .init(string: "{\"kind\":\"event\",\"summary\":\"Build ready after restart\",\"externalEventId\":\"inbox-build-227\",\"payload\":{\"status\":\"ready\"}}")
            }
            #expect(posted.status == .accepted)
            let eventId = try inboxObject(posted)["id"] as? String ?? ""

            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(apiKey)"

            let hints = try await client.send(.get, headers: agentHeaders, to: "/internal/agent-api/wake-hints?since=0")
            #expect(hints.status == .ok)
            let hintRows = try inboxObject(hints)["wake_hints"] as? [[String: Any]] ?? []
            #expect(hintRows.count == 1)
            #expect(hintRows.first?["message_id"] as? String == eventId)
            #expect(hintRows.first?["seq"] == nil || hintRows.first?["seq"] is NSNull)
            #expect(hintRows.first?["wake_reason"] as? String == "message_pending")

            let stream = try await client.send(.get, headers: agentHeaders, to: "/internal/agent-api/wake-hints/stream?since=0")
            #expect(stream.status == .ok)
            #expect((stream.headers[HTTPField.Name("Content-Type")!] ?? "").hasPrefix("text/event-stream"))
            let streamText = stream.body.string ?? ""
            #expect(streamText.contains(": connected"))
            #expect(streamText.contains("event: wake-hint"))
            #expect(streamText.contains("\"message_id\":\"\(eventId)\""))

            let events = try await client.send(.get, headers: agentHeaders, to: "/internal/agent-api/events")
            #expect(events.status == .ok)
            let eventRows = try inboxObject(events)["events"] as? [[String: Any]] ?? []
            #expect(eventRows.count == 1)
            #expect(eventRows.first?["message_id"] as? String == eventId)
            #expect(eventRows.first?["sender_type"] as? String == "third_party_app")
            let thirdParty = eventRows.first?["third_party_event"] as? [String: Any]
            #expect(thirdParty?["id"] as? String == eventId)
            #expect((thirdParty?["source"] as? [String: Any])?["client_id"] as? String == "agent-inbox-227")

            let replay = try await client.send(.get, headers: agentHeaders, to: "/internal/agent-api/events")
            #expect(((try inboxObject(replay)["events"]) as? [[String: Any]])?.isEmpty == true)
            let hintsAfter = try await client.send(.get, headers: agentHeaders, to: "/internal/agent-api/wake-hints?since=0")
            #expect(((try inboxObject(hintsAfter)["wake_hints"]) as? [[String: Any]])?.isEmpty == true)
        }
    }
}

@Test func daemonReportEndsTheThirdPartyEventReplay() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111228"
    let serverId = "33333333-3333-4333-8333-333333333422"
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-report-228", name: "Agent Report", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "ReportBot")
    let otherAgentId = accounts.oauth.createAgent(serverId: serverId, name: "OtherBot")
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Report Event Client",
        clientId: "agent-report-228",
        allowedScopes: ["openid", "agent:event:write"]
    )
    let readKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "report-test")
    let otherReadKey = accounts.mintAgentCredential(agentId: otherAgentId, scopes: ["read"], name: "other-report-test")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var jsonHeaders = HTTPFields()
            jsonHeaders[.contentType] = "application/json"
            let requested = try await client.send(.post, headers: jsonHeaders, to: "/api/oauth/requests/agent") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"serverSlug\":\"agent-report-228\",\"agentName\":\"ReportBot\",\"scopes\":[\"agent:event:write\"]}")
            }
            let requestId = try inboxObject(requested)["requestId"] as? String ?? ""
            let tokenBody: [String: Any] = [
                "clientId": created.clientId,
                "clientSecret": created.clientSecret,
                "grantType": "urn:slock:grant-type:agent_request",
                "requestId": requestId,
                "resource": "urn:raft:server:\(serverId):agent-inbound",
            ]
            let tokenData = try JSONSerialization.data(withJSONObject: tokenBody)
            let exchanged = try await client.send(.post, headers: jsonHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: String(decoding: tokenData, as: UTF8.self))
            }
            let accessToken = try inboxObject(exchanged)["access_token"] as? String ?? ""

            var eventHeaders = HTTPFields()
            eventHeaders[.contentType] = "application/json"
            eventHeaders[.authorization] = "Bearer \(accessToken)"
            let posted = try await client.send(.post, headers: eventHeaders, to: "/api/oauth/agent-events") { request in
                request.body = .init(string: "{\"kind\":\"event\",\"summary\":\"Stamp: PR review requested\",\"externalEventId\":\"stamp-review-228\",\"payload\":{\"pr\":228}}")
            }
            #expect(posted.status == .accepted)
            let eventId = try inboxObject(posted)["id"] as? String ?? ""

            func report(_ key: String, _ ids: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                headers[.authorization] = "Bearer \(key)"
                return try await client.send(.post, headers: headers, to: "/internal/agent-api/third-party-events/delivered") { request in
                    request.body = .init(string: "{\"eventIds\":\(ids)}")
                }
            }

            let foreign = try await report(otherReadKey, "[\"\(eventId)\"]")
            #expect(foreign.status == .ok)
            #expect(try inboxObject(foreign)["delivered"] as? Int == 0)

            var readHeaders = HTTPFields()
            readHeaders[.authorization] = "Bearer \(readKey)"
            let before = try await client.send(.get, headers: readHeaders, to: "/internal/agent-api/wake-hints?since=0")
            #expect((try inboxObject(before)["wake_hints"] as? [[String: Any]])?.count == 1)

            let reported = try await report(readKey, "[\"\(eventId)\"]")
            #expect(reported.status == .ok)
            #expect(try inboxObject(reported)["delivered"] as? Int == 1)

            let replay = try await client.send(.get, headers: readHeaders, to: "/internal/agent-api/events")
            #expect(((try inboxObject(replay)["events"]) as? [[String: Any]])?.isEmpty == true)

            let again = try await report(readKey, "[\"\(eventId)\"]")
            #expect(try inboxObject(again)["delivered"] as? Int == 0)

            let empty = try await report(readKey, "[]")
            #expect(empty.status == .badRequest)

            let mixed = try await report(readKey, "[\"\(eventId)\",\"not-a-third-party-event-id\"]")
            #expect(mixed.status == .badRequest)
            #expect(try inboxObject(mixed)["code"] as? String == "event_ids_invalid")

            let upper = try await report(readKey, "[\"EEEEEEEE-0000-4000-8000-000000000179\"]")
            #expect(upper.status == .ok)
            #expect(try inboxObject(upper)["delivered"] as? Int == 0)
        }
    }
}
