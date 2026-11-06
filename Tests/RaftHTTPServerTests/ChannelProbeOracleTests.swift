import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func channelProbesKeepStrangerAndExMemberAnswersIndistinguishable() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001012001"
    let ownerId = "11111111-1111-4111-8111-000001012001"
    let exId = "11111111-1111-4111-8111-000001012002"
    let strangerId = "11111111-1111-4111-8111-000001012003"
    let exEmail = "probe-ex@slock.test"
    let strangerEmail = "probe-stranger@slock.test"
    for (id, email) in [(ownerId, "probe-owner@slock.test"), (exId, exEmail), (strangerId, strangerEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "probe", name: "Probe", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: exId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: strangerId, role: "member")
    let secret = accounts.oauth.createChannel(serverId: serverId, name: "probe-secret", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: secret, memberId: ownerId, kind: "private", name: "probe-secret")
    accounts.addPostableChannel(serverId: serverId, channelId: secret, memberId: exId, kind: "private", name: "probe-secret")
    accounts.oauth.addChannelHuman(channelId: secret, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: secret, userId: exId)
    let parent = accounts.addChannelMessageForTesting(channelId: secret, content: "secret parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: secret, parentMessageId: parent)
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: secret, parentMessageId: parent, name: "thread")

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
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let stranger = try await login(strangerEmail)
            let exMember = try await login(exEmail)
            let missing = "99999999-9999-4999-8999-999999999999"
            let probeMessage = "00000000-0000-4000-8000-000000000000"

            func probes(_ token: String, _ channel: String) async throws -> [(String, HTTPResponse.Status, String)] {
                let h = headers(token)
                var results: [(String, HTTPResponse.Status, String)] = []
                func record(_ name: String, _ response: ClientResponse) {
                    results.append((name, response.status, response.body.string ?? ""))
                }
                record("files", try await client.get(URI(string: "/api/channels/\(channel)/files"), headers: h))
                record("threads", try await client.get(URI(string: "/api/channels/\(channel)/threads"), headers: h))
                record("thread-info", try await client.get(URI(string: "/api/channels/\(channel)/threads/\(probeMessage)"), headers: h))
                record("thread-create", try await client.send(.post, headers: h, to: URI(string: "/api/channels/\(channel)/threads")) { request in
                    request.body = .init(string: "{\"parentMessageId\":\"\(probeMessage)\"}")
                })
                record("messages", try await client.get(URI(string: "/api/messages/channel/\(channel)"), headers: h))
                record("sync", try await client.get(URI(string: "/api/messages/sync?channel_id=\(channel)"), headers: h))
                return results
            }

            let real = try await probes(stranger, secret)
            let absent = try await probes(stranger, missing)
            for index in real.indices {
                #expect(real[index].0 == absent[index].0)
                #expect(real[index].1 == .notFound, "\(real[index].0) must be 404")
                #expect(absent[index].1 == .notFound, "\(absent[index].0) must be 404")
                #expect(real[index].2 == absent[index].2, "\(real[index].0) bodies differ")
            }

            accounts.markInboxResidueForTesting(userId: exId, channelId: secret)
            accounts.removeChannelMember(channelId: secret, memberId: exId)
            accounts.oauth.removeChannelHuman(channelId: secret, userId: exId)
            let residue = try await probes(exMember, secret)
            for result in residue {
                #expect(result.1 == .forbidden, "\(result.0) must answer a residue holder with 403")
            }
        }
    }
}
