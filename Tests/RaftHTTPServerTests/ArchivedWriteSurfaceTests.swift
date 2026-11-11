import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func archivedChannelFreezesEveryWritePath() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111478"
    let memberId = "11111111-1111-4111-8111-111111111479"
    let serverId = "33333333-3333-4333-8333-333333333584"
    accounts.addAccount(id: ownerId, email: "archived-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "archived-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "archived-surface", name: "Archived Surface", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func userHeaders(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("archived-owner@slock.test")
            let memberToken = try await login("archived-member@slock.test")
            let channel = try await client.send(.post, headers: userHeaders(ownerToken), to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"archived-surface-room\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: memberId, name: "archived-surface-room")
            accounts.oauth.addChannelHuman(channelId: channelId, userId: memberId)
            let agent = accounts.oauth.createAgent(serverId: serverId, name: "archived-agent")
            accounts.oauth.addChannelAgent(channelId: channelId, agentId: agent)
            let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "archived-machine")
            let apiKey = accounts.machineAPIKey(machineId: machine) ?? ""
            accounts.assignAgentMachineForTesting(agentId: agent, machineId: machine)
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(apiKey)"
            agentHeaders[.contentType] = "application/json"

            #expect(try await client.send(.post, headers: userHeaders(ownerToken), to: "/api/channels/\(channelId)/archive").status == .ok)

            let probes: [(label: String, method: String, path: String, body: String?, headers: HTTPFields)] = [
                ("rename", "PATCH", "/api/channels/\(channelId)", "{\"name\":\"should-not-rename\"}", userHeaders(ownerToken)),
                ("add member", "POST", "/api/channels/\(channelId)/members", "{\"agentId\":\"\(agent)\"}", userHeaders(ownerToken)),
                ("batch members", "POST", "/api/channels/\(channelId)/members/batch", "{\"userIds\":[\"\(memberId)\"],\"agentIds\":[\"\(agent)\"]}", userHeaders(ownerToken)),
                ("remove human", "DELETE", "/api/channels/\(channelId)/members/user/\(memberId)", nil, userHeaders(ownerToken)),
                ("remove agent", "DELETE", "/api/channels/\(channelId)/members/agent/\(agent)", nil, userHeaders(ownerToken)),
                ("join", "POST", "/api/channels/\(channelId)/join", nil, userHeaders(memberToken)),
                ("leave", "POST", "/api/channels/\(channelId)/leave", nil, userHeaders(ownerToken)),
                ("thread", "POST", "/api/channels/\(channelId)/threads", "{\"parentMessageId\":\"\(UUID().uuidString.lowercased())\",\"content\":\"no\"}", userHeaders(ownerToken)),
                ("message", "POST", "/api/messages", "{\"channelId\":\"\(channelId)\",\"content\":\"no\"}", userHeaders(ownerToken)),
                ("agent send", "POST", "/internal/agent/\(agent)/send", "{\"target\":\"#archived-surface-room\",\"content\":\"no\"}", agentHeaders),
                ("agent join", "POST", "/internal/agent/\(agent)/channels/\(channelId)/join", nil, agentHeaders),
                ("agent leave", "POST", "/internal/agent/\(agent)/channels/\(channelId)/leave", nil, agentHeaders),
            ]
            for (label, method, path, body, headers) in probes {
                let httpMethod: HTTPRequest.Method = switch method {
                case "PATCH": .patch
                case "DELETE": .delete
                default: .post
                }
                let response = try await client.send(httpMethod, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                let object = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                #expect(response.status == .conflict, "\(label) must be frozen")
                #expect(object?["code"] as? String == "channel_archived", "\(label) must return channel_archived")
            }
        }
    }
}
