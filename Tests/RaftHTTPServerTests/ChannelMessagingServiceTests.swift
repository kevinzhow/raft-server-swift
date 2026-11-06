import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Locks the channel-messaging task creation operation and the realtime frame
/// it owns, both before and after the Feature -> Service -> Store migration.
///
/// `POST /api/tasks/channel/:channelId` is the `task:created` producer. The
/// upstream contract is the exact reply JSON, the usual JSON headers, and the
/// `channel:<id>` / `task:created` frame whose payload is sorted-key JSON.

private struct CapturedFrame: Sendable, Equatable {
    let room: String
    let event: String
    let payloadJSON: String
}

private final class FrameCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CapturedFrame] = []

    func record(room: String, event: String, payload: String?) {
        lock.lock()
        frames.append(CapturedFrame(room: room, event: event, payloadJSON: payload ?? ""))
        lock.unlock()
    }

    var recorded: [CapturedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}

private func channelMessagingLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    let body = (response.body.string ?? "").data(using: .utf8) ?? Data()
    return (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func channelMessagingHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func sortedJSON(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

@Test func createChannelTasksPublishesTheTypedTaskCreatedFrame() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111772001"
    let serverId = "33333333-3333-4333-8333-333333772001"
    accounts.addAccount(id: ownerId, email: "channel-messaging-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-messaging", name: "Channel Messaging", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "builder", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "builder")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)

    let capture = FrameCapture()
    accounts.realtimeEmitter = { room, event, payload in
        capture.record(room: room, event: event, payload: payload)
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await channelMessagingLogin(client, email: "channel-messaging-owner@slock.test")
            let headers = channelMessagingHeaders(token, serverId)
            let created = try await client.send(.post, headers: headers, to: "/api/tasks/channel/\(channelId)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"ship it\",\"description\":\"with tests\"}]}")
            }
            #expect(created.status == .ok)
            #expect(created.headers[.contentType] == "application/json; charset=utf-8")
            #expect(created.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            let body = created.body.string ?? ""
            #expect(body.hasPrefix("{\"taskIds\":[\""))
            #expect(created.headers[.contentLength] == String(body.utf8.count))

            let taskIds = try #require(
                (try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["taskIds"] as? [String]
            )
            #expect(taskIds.count == 1)

            let frames = capture.recorded
            #expect(frames.count == 1)
            let frame = try #require(frames.first)
            #expect(frame.room == "channel:\(channelId)")
            #expect(frame.event == "task:created")
            let expectedPayload = sortedJSON(TaskCreatedPayload(
                channelId: channelId,
                tasks: [TaskCreatedItemDTO(
                    id: try #require(taskIds.first),
                    channelId: channelId,
                    title: "ship it",
                    status: "todo"
                )]
            ))
            #expect(frame.payloadJSON == expectedPayload)
        }
    }
}

@Test func createChannelTasksKeepsEveryPublishedErrorByteIdentical() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111772002"
    let memberId = "11111111-1111-4111-8111-111111772003"
    let serverId = "33333333-3333-4333-8333-333333772002"
    for (id, email) in [
        (ownerId, "channel-messaging-errors-owner@slock.test"),
        (memberId, "channel-messaging-errors-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-messaging-errors", name: "Errors", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "errors", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "errors")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await channelMessagingLogin(client, email: "channel-messaging-errors-owner@slock.test")
            let memberToken = try await channelMessagingLogin(client, email: "channel-messaging-errors-member@slock.test")
            let headers = channelMessagingHeaders(token, serverId)
            let memberHeaders = channelMessagingHeaders(memberToken, serverId)

            // Missing auth: 401 before any policy read.
            let unauthorized = try await client.send(.post, to: "/api/tasks/channel/\(channelId)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"nope\"}]}")
            }
            #expect(unauthorized.status == .unauthorized)
            #expect(unauthorized.body.string == "{\"error\":\"Unauthorized\"}")

            // Not a server member: 403.
            accounts.oauth.removeMember(serverId: serverId, userId: memberId)
            let notMember = try await client.send(.post, headers: memberHeaders, to: "/api/tasks/channel/\(channelId)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"nope\"}]}")
            }
            #expect(notMember.status == .forbidden)
            #expect(notMember.body.string == "{\"error\":\"Not a member of this server\"}")
            accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

            // Unknown channel: 404.
            let missing = try await client.send(.post, headers: headers, to: "/api/tasks/channel/not-a-channel") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"nope\"}]}")
            }
            #expect(missing.status == .notFound)
            #expect(missing.body.string == "{\"error\":\"Channel not found\"}")

            // Public channel non-member: 403 before the archived and body checks.
            let readOnly = try await client.send(.post, headers: memberHeaders, to: "/api/tasks/channel/\(channelId)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"nope\"}]}")
            }
            #expect(readOnly.status == .forbidden)
            #expect(readOnly.body.string == "{\"error\":\"Join the channel to change tasks\"}")

            // Archived channel: 409 with the machine-readable code.
            accounts.oauth.setChannelArchived(id: channelId, archivedAt: Date())
            let archived = try await client.send(.post, headers: headers, to: "/api/tasks/channel/\(channelId)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"nope\"}]}")
            }
            #expect(archived.status == .conflict)
            #expect(archived.body.string == "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
            accounts.oauth.setChannelArchived(id: channelId, archivedAt: nil)

            // Malformed and empty task lists keep the 400.
            for bodyJSON in ["{}", "{\"tasks\":[]}", "{\"tasks\":[\"nope\"]}", "{\"tasks\":null}"] {
                let invalid = try await client.send(.post, headers: headers, to: "/api/tasks/channel/\(channelId)") { request in
                    request.body = .init(string: bodyJSON)
                }
                #expect(invalid.status == .badRequest, "expected 400 for \(bodyJSON)")
                #expect(invalid.body.string == "{\"error\":\"Invalid task list\"}")
            }
        }
    }
}

@Test func createChannelTasksSkipsUntitledAndWrongTypedTitleRowsLikeTheRawParser() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111772004"
    let serverId = "33333333-3333-4333-8333-333333772003"
    accounts.addAccount(id: ownerId, email: "channel-messaging-lenient@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "channel-messaging-lenient", name: "Lenient", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "lenient", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "lenient")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await channelMessagingLogin(client, email: "channel-messaging-lenient@slock.test")
            let headers = channelMessagingHeaders(token, serverId)
            let created = try await client.send(.post, headers: headers, to: "/api/tasks/channel/\(channelId)") { request in
                // Empty and wrong-typed titles are dropped by the raw parser
                // before it writes; the batch itself is still valid.
                request.body = .init(string: "{\"tasks\":[{\"title\":\"\"},{\"title\":5},{\"title\":\"kept\"}]}")
            }
            #expect(created.status == .ok)
            let taskIds = try #require(
                (try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any])?["taskIds"] as? [String]
            )
            #expect(taskIds.count == 1)
        }
    }
}
