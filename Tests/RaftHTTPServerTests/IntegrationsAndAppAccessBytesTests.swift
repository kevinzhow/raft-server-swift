import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Byte-exact lock for the integrations and app-access surface: setup
/// declarations, marketplace installs, agent grants, app events, attachment
/// comments and the agent integration-app routes.
///
/// Each line is `name | status | selected headers | body`. UUIDs are renamed
/// `<uN>` by first appearance and timestamps become `<ts>`, so the member order,
/// escaping, header set and status of every reply is compared literally.
private struct BytesFixture {
    let accounts = EmailLoginDirectory()
    let sourceId = "33333333-3333-4333-8333-000001300001"
    let serverId = "33333333-3333-4333-8333-000001300002"
    let ownerId = "11111111-1111-4111-8111-000001300001"
    let creatorId = "11111111-1111-4111-8111-000001300002"
    let memberId = "11111111-1111-4111-8111-000001300003"
    let strangerId = "11111111-1111-4111-8111-000001300004"
}

private final class Normalizer: @unchecked Sendable {
    private var seen: [String: Int] = [:]
    private let uuid = try! NSRegularExpression(pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    private let stamp = try! NSRegularExpression(pattern: "\\d{4}-\\d\\d-\\d\\dT[\\d:.]+Z")
    private let cursor = try! NSRegularExpression(pattern: "\"\\d{13}\\.")

    func callAsFunction(_ text: String) -> String {
        var out = stamp.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<ts>"
        )
        out = cursor.stringByReplacingMatches(
            in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "\"<ms>."
        )
        let matches = uuid.matches(in: out, range: NSRange(out.startIndex..., in: out))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let id = String(out[range])
            let index = seen[id] ?? { seen[id] = seen.count + 1; return seen.count }()
            out.replaceSubrange(range, with: "<u\(index)>")
        }
        return out
    }
}

private func uuidIn(_ body: String, key: String) -> String {
    let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    return object?[key] as? String ?? ""
}

@Test func integrationsAndAppAccessRepliesAreByteStable() async throws {
    let f = BytesFixture()
    let accounts = f.accounts
    for (id, email) in [(f.ownerId, "owner"), (f.creatorId, "creator"), (f.memberId, "member"), (f.strangerId, "stranger")] {
        accounts.addAccount(id: id, email: "\(email)@bytes.test", password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: f.sourceId, slug: "bytes-src", name: "Bytes Source", ownerId: f.ownerId)
    accounts.oauth.addOwnedServer(id: f.serverId, slug: "bytes-dst", name: "Bytes Target", ownerId: f.ownerId)
    for user in [f.creatorId, f.memberId] {
        accounts.oauth.addMember(serverId: f.serverId, userId: user, role: "member")
    }
    let published = try accounts.oauth.createClient(
        serverId: f.sourceId, createdByUserId: f.ownerId, name: "Pub / App", clientId: "pub-app",
        description: "Public \"app\"", homepageUrl: "https://pub.example.test/home",
        returnUrl: "https://pub.example.test/cb", allowedScopes: ["openid", "profile"],
        setupUrl: "https://pub.example.test/setup", setupDescription: "Pick a repo"
    )
    accounts.oauth.setClientAppType(clientRecordId: published.id, appType: "third_party_global")
    accounts.oauth.publishClient(clientRecordId: published.id, humanMarketplaceVisible: true)
    let local = try accounts.oauth.createClient(
        serverId: f.serverId, createdByUserId: f.ownerId, name: "Local App", clientId: "local-app",
        description: "Local", homepageUrl: "https://local.example.test/h",
        allowedScopes: ["agent:notification:write", "openid"]
    )
    let memberApp = try accounts.oauth.createClient(
        serverId: f.serverId, createdByUserId: f.memberId, name: "Member App", clientId: "member-app",
        allowedScopes: ["agent:notification:write"]
    )
    let agent = accounts.oauth.createAgent(serverId: f.serverId, name: "BytesBot", creatorUserId: f.creatorId, runtime: "claude")
    accounts.oauth.addClientMaintainer(clientRecordId: local.id, agentId: agent)
    let agentKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "bytes")
    let writeOnlyKey = accounts.mintAgentCredential(agentId: agent, scopes: ["write"], name: "bytes-w")

    // Channel, attachments and messages for the comment routes.
    let channelId = accounts.oauth.createChannel(serverId: f.serverId, name: "bytes-ch", creatorUserId: f.ownerId)
    for user in [f.ownerId, f.memberId] {
        accounts.addPostableChannel(serverId: f.serverId, channelId: channelId, memberId: user, name: "bytes-ch")
        accounts.oauth.addChannelHuman(channelId: channelId, userId: user)
    }
    let host = accounts.addChannelMessageForTesting(channelId: channelId, content: "host", senderId: f.ownerId)
    let linked = accounts.addChannelAttachment(channelId: channelId, uploaderId: f.ownerId, filename: "a.pdf", mimeType: "application/pdf", sizeBytes: 3, messageId: host)
    let unlinked = accounts.addChannelAttachment(channelId: channelId, uploaderId: f.ownerId, filename: "b.pdf", mimeType: "application/pdf", sizeBytes: 3)

    // Agent-authored messages for deliveries and resolve.
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agent)
    let agentMessage = accounts.addChannelMessageForTesting(
        id: "aaaaaaaa-0000-4000-8000-00000000000a", channelId: channelId, content: "agent says \"hi\"",
        senderId: agent, senderType: "agent"
    )
    accounts.addChannelMessageForTesting(
        id: "aaaaaaaa-0000-4000-8000-00000000000b", channelId: channelId, content: "second",
        senderId: agent, senderType: "agent"
    )
    accounts.addStoredMentionForTesting(channelId: channelId, messageId: agentMessage, targetId: agent, targetType: "agent", handle: "bytesbot", terminalCode: "QUOTA_LIMITED")

    // App events for the grant surface.
    let now = Date()
    let eventIds = (0..<3).map { _ in UUID().uuidString.lowercased() }
    for index in 0..<3 {
        accounts.oauth.seedAgentAppEventForTesting(
            id: eventIds[index], agentId: agent, clientRecordId: local.id, summary: "ev \(index) / \"q\"",
            status: index == 2 ? "delivered" : "queued", expiresAt: now.addingTimeInterval(86_400),
            createdAt: now.addingTimeInterval(-Double(3 - index) * 60), payloadJSON: "{\"n\":\(index)}"
        )
    }

    let owner = accounts.mintAccessTokenForTesting(userId: f.ownerId)
    let creator = accounts.mintAccessTokenForTesting(userId: f.creatorId)
    let member = accounts.mintAccessTokenForTesting(userId: f.memberId)
    let stranger = accounts.mintAccessTokenForTesting(userId: f.strangerId)
    let normalize = Normalizer()
    nonisolated(unsafe) var lines: [String] = []

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            @discardableResult
            func call(
                _ name: String, _ method: HTTPRequest.Method, _ path: String,
                token: String? = nil, server: String? = nil, body: String? = nil, json: Bool = true
            ) async throws -> String {
                var headers = HTTPFields()
                if let token { headers[.authorization] = "Bearer \(token)" }
                if let server { headers[HTTPField.Name("X-Server-Id")!] = server }
                if body != nil, json { headers[.contentType] = "application/json" }
                let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                let text = response.body.string ?? ""
                let header = ["Content-Type", "Cache-Control", "X-Robots-Tag", "Content-Length"].map { name in
                    "\(name)=\(response.headers[HTTPField.Name(name)!] ?? "-")"
                }.joined(separator: ";")
                lines.append(normalize("\(name) | \(response.status.code) | \(header) | \(text)"))
                return text
            }
            let s = f.serverId

            // Setup declaration and marketplace install.
            try await call("setup-before", .get, "/api/integrations/clients/\(published.id)/setup", token: owner, server: s)
            try await call("setup-unauth", .get, "/api/integrations/clients/\(published.id)/setup", server: s)
            try await call("setup-stranger", .get, "/api/integrations/clients/\(published.id)/setup", token: stranger, server: s)
            try await call("install-unknown", .post, "/api/integrations/marketplace/nope/install", token: owner, server: s)
            try await call("install-member", .post, "/api/integrations/marketplace/\(published.id)/install", token: member, server: s)
            let installed = try await call("install", .post, "/api/integrations/marketplace/\(published.id)/install", token: owner, server: s)
            let installationId = uuidIn(installed, key: "id")
            try await call("setup-owner", .get, "/api/integrations/clients/\(published.id)/setup", token: owner, server: s)
            try await call("setup-member", .get, "/api/integrations/clients/\(published.id)/setup", token: member, server: s)
            try await call("patch-badbody", .patch, "/api/integrations/clients/\(published.id)", token: owner, server: s, body: "[1]")
            try await call("patch-member", .patch, "/api/integrations/clients/\(published.id)", token: member, server: s, body: "{}")
            try await call("patch-unknown", .patch, "/api/integrations/clients/nope", token: owner, server: s, body: "{}")
            try await call("patch-description", .patch, "/api/integrations/clients/\(published.id)", token: owner, server: s, body: "{\"setupDescription\":\"Pick \\\"repo\\\" / x\"}")
            try await call("patch-badurl", .patch, "/api/integrations/clients/\(published.id)", token: owner, server: s, body: "{\"setupUrl\":\"http://evil.example.test/x\"}")
            try await call("patch-nonstring", .patch, "/api/integrations/clients/\(published.id)", token: owner, server: s, body: "{\"setupUrl\":5}")
            try await call("patch-nocontenttype", .patch, "/api/integrations/clients/\(published.id)", token: owner, server: s, body: "{\"setupUrl\":\"https://pub.example.test/v2\"}", json: false)

            // App backend setup report.
            let report = "/api/oauth/installations/\(installationId)/setup"
            let secret = published.clientSecret
            try await call("report-auth", .put, report, token: owner, body: "{}")
            try await call("report-nobody", .put, report)
            try await call("report-badstatus", .put, report, body: "{\"clientId\":\"pub-app\",\"clientSecret\":\"\(secret)\",\"revision\":2,\"status\":\"done\"}")
            try await call("report-badsecret", .put, report, body: "{\"clientId\":\"pub-app\",\"clientSecret\":\"bad\",\"revision\":2,\"status\":\"complete\"}")
            try await call("report-conflict", .put, report, body: "{\"clientId\":\"pub-app\",\"clientSecret\":\"\(secret)\",\"revision\":1,\"status\":\"complete\"}")
            try await call("report-complete", .put, report, body: "{\"clientId\":\"pub-app\",\"clientSecret\":\"\(secret)\",\"revision\":3,\"status\":\"complete\"}", json: false)
            try await call("report-pending", .put, report, body: "{\"clientId\":\"pub-app\",\"clientSecret\":\"\(secret)\",\"revision\":3.0,\"status\":\"pending\"}")
            try await call("setup-after-report", .get, "/api/integrations/clients/\(published.id)/setup", token: owner, server: s)
            try await call("report-unknown", .put, "/api/oauth/installations/\(UUID().uuidString.lowercased())/setup", body: "{\"clientId\":\"pub-app\",\"clientSecret\":\"\(secret)\",\"revision\":2,\"status\":\"pending\"}")
            try await call("uninstall-member", .delete, "/api/integrations/marketplace/\(published.id)/install", token: member, server: s)
            try await call("uninstall", .delete, "/api/integrations/marketplace/\(published.id)/install", token: owner, server: s)
            try await call("uninstall-again", .delete, "/api/integrations/marketplace/\(published.id)/install", token: owner, server: s)

            // Agent grants.
            let grantPath = "/api/integrations/agents/\(agent)/grants"
            try await call("grant-unauth", .post, grantPath, body: "{}")
            try await call("grant-missing", .post, grantPath, token: creator, server: s, body: "{}")
            try await call("grant-stranger", .post, grantPath, token: stranger, server: s, body: "{\"clientId\":\"\(local.id)\",\"scopes\":[\"openid\"]}")
            try await call("grant-badscope", .post, grantPath, token: creator, server: s, body: "{\"clientId\":\"\(local.id)\",\"scopes\":[\"bogus\"]}")
            try await call("grant-unknownapp", .post, grantPath, token: creator, server: s, body: "{\"clientId\":\"nope\",\"scopes\":[\"openid\"]}")
            try await call("grant-unknownagent", .post, "/api/integrations/agents/\(UUID().uuidString.lowercased())/grants", token: creator, server: s, body: "{\"clientId\":\"\(local.id)\",\"scopes\":[\"openid\"]}")
            let granted = try await call("grant-create", .post, grantPath, token: creator, server: s, body: "{\"clientId\":\"\(local.id)\",\"scopes\":[\"openid\",7,\"agent:notification:write\"]}")
            try await call("grant-repeat", .post, grantPath, token: creator, server: s, body: "{\"clientId\":\"\(local.id)\",\"scopes\":[\"openid\"]}", json: false)
            try await call("grants-list", .get, grantPath, token: creator, server: s)
            try await call("grants-stranger", .get, grantPath, token: stranger, server: s)
            try await call("grants-member-empty", .get, "/api/integrations/agents/\(accounts.oauth.createAgent(serverId: s, name: "Lonely", creatorUserId: f.ownerId))/grants", token: member, server: s)
            try await call("grants-unknown", .get, "/api/integrations/agents/nope/grants", token: creator, server: s)
            try await call("grantable", .get, "/api/integrations/agents/\(agent)/grantable-apps", token: creator, server: s)
            try await call("grantable-stranger", .get, "/api/integrations/agents/\(agent)/grantable-apps", token: stranger, server: s)
            try await call("grantable-unknown", .get, "/api/integrations/agents/nope/grantable-apps", token: creator, server: s)
            let grantId = uuidIn(granted, key: "grantId")
            try await call("revoke-stranger", .post, "/api/integrations/grants/\(grantId)/revoke", token: stranger, server: s)
            try await call("revoke", .post, "/api/integrations/grants/\(grantId)/revoke", token: creator, server: s)
            try await call("revoke-again", .post, "/api/integrations/grants/\(grantId)/revoke", token: creator, server: s)
            try await call("revoke-unauth", .post, "/api/integrations/grants/\(grantId)/revoke")

            // Access requests.
            let requested = accounts.oauth.requestAgentAccess(
                authorization: nil,
                body: "{\"clientId\":\"member-app\",\"clientSecret\":\"\(memberApp.clientSecret)\",\"serverSlug\":\"bytes-dst\",\"agentId\":\"\(agent)\",\"scopes\":[\"agent:notification:write\"]}"
            )
            let requestId = uuidIn(requested.body, key: "requestId")
            try await call("approve-stranger", .post, "/api/integrations/requests/\(requestId)/approve", token: stranger, server: s, body: "{\"remember\":true}")
            try await call("approve-unknown", .post, "/api/integrations/requests/\(UUID().uuidString.lowercased())/approve", token: creator, server: s, body: "{}")
            try await call("approve-unauth", .post, "/api/integrations/requests/\(requestId)/approve")
            try await call("approve", .post, "/api/integrations/requests/\(requestId)/approve", token: creator, server: s, body: "{\"remember\":1}", json: false)

            // App events.
            let events = "/api/integrations/agents/\(agent)/events"
            let page = try await call("events-page", .get, "\(events)?limit=2", token: creator, server: s)
            try await call("events-all", .get, events, token: creator, server: s)
            try await call("events-badlimit", .get, "\(events)?limit=0", token: creator, server: s)
            try await call("events-nanlimit", .get, "\(events)?limit=abc", token: creator, server: s)
            try await call("events-toolarge", .get, "\(events)?limit=101", token: creator, server: s)
            try await call("events-badcursor", .get, "\(events)?before=nope", token: creator, server: s)
            try await call("events-stranger", .get, events, token: stranger, server: s)
            try await call("events-unknown", .get, "/api/integrations/agents/nope/events", token: creator, server: s)
            try await call("event-detail", .get, "\(events)/\(eventIds[2])", token: creator, server: s)
            try await call("event-detail-unknown", .get, "\(events)/\(UUID().uuidString.lowercased())", token: creator, server: s)
            try await call("event-detail-stranger", .get, "\(events)/\(eventIds[2])", token: stranger, server: s)
            _ = page

            // Attachment comments.
            try await call("counts", .get, "/api/attachments/comments/counts?ids=\(linked),\(unlinked),nope,\(linked)", token: member, server: s)
            try await call("counts-empty", .get, "/api/attachments/comments/counts?ids=", token: member, server: s)
            try await call("counts-unauth", .get, "/api/attachments/comments/counts?ids=\(linked)", server: s)
            try await call("comments-empty", .get, "/api/attachments/\(linked)/comments", token: member, server: s)
            try await call("comments-baduuid", .get, "/api/attachments/nope/comments", token: member, server: s)
            try await call("comments-stranger", .get, "/api/attachments/\(linked)/comments", token: stranger, server: s)
            try await call("comments-unlinked", .get, "/api/attachments/\(unlinked)/comments", token: member, server: s)
            let commentPath = "/api/attachments/\(linked)/comments"
            try await call("comment-nocontent", .post, commentPath, token: member, server: s, body: "{}")
            try await call("comment-unauth", .post, commentPath, server: s, body: "{}")
            try await call("comment-unlinked", .post, "/api/attachments/\(unlinked)/comments", token: member, server: s, body: "{\"content\":\"x\"}")
            try await call("comment-baduuid", .post, "/api/attachments/nope/comments", token: member, server: s, body: "{}")
            try await call("comment-stranger", .post, commentPath, token: stranger, server: s, body: "{\"content\":\"x\"}")
            try await call("comment-badmentions", .post, commentPath, token: member, server: s, body: "{\"content\":\"x\",\"mentions\":[{\"type\":\"user\"}]}")
            try await call("comment-badanchor", .post, commentPath, token: member, server: s, body: "{\"content\":\"x\",\"anchor\":{\"type\":\"nope\",\"data\":{}}}")
            try await call("comment-anchor-shape", .post, commentPath, token: member, server: s, body: "{\"content\":\"x\",\"anchor\":{\"type\":\"lines\",\"data\":{\"start\":0,\"end\":2}}}")
            try await call("comment-anchor-notobject", .post, commentPath, token: member, server: s, body: "{\"content\":\"x\",\"anchor\":5}")
            let huge = String(repeating: "q", count: 5000)
            try await call("comment-anchor-large", .post, commentPath, token: member, server: s, body: "{\"content\":\"x\",\"anchor\":{\"type\":\"lines\",\"data\":{\"start\":1,\"end\":2,\"quote\":\"\(huge)\"}}}")
            try await call("comment-lines", .post, commentPath, token: member, server: s, body: "{\"content\":\"hi \\\"there\\\" / ok\",\"anchor\":{\"type\":\"lines\",\"data\":{\"start\":1,\"end\":2,\"quote\":\"a/b\",\"extra\":1}},\"mentions\":[{\"type\":\"user\",\"id\":\"\(f.ownerId)\",\"name\":\"owner\"}]}")
            try await call("comment-md", .post, commentPath, token: member, server: s, body: "{\"content\":\"md\",\"anchor\":{\"type\":\"md-section\",\"data\":{\"headingId\":\"h1\",\"headingTitle\":\"T\"}}}", json: false)
            try await call("comment-html", .post, commentPath, token: owner, server: s, body: "{\"content\":\"html\",\"anchor\":{\"type\":\"html-region\",\"data\":{\"x\":1.4,\"y\":2,\"w\":3,\"h\":4,\"viewportWidth\":5,\"documentWidth\":6,\"documentHeight\":7,\"quote\":\"q\"}}}")
            try await call("comment-plain", .post, commentPath, token: member, server: s, body: "{\"content\":\"plain\"}")
            try await call("counts-after", .get, "/api/attachments/comments/counts?ids=\(linked)", token: member, server: s)
            try await call("comments-after", .get, commentPath, token: owner, server: s)
            accounts.setFeatureFlagKillSwitchForTesting(key: "attachment_comments_v0", killSwitch: true)
            try await call("comments-disabled", .get, commentPath, token: member, server: s)
            try await call("comment-disabled", .post, commentPath, token: member, server: s, body: "{}")
            try await call("counts-disabled", .get, "/api/attachments/comments/counts?ids=\(linked)", token: member, server: s)
            accounts.setFeatureFlagKillSwitchForTesting(key: "attachment_comments_v0", killSwitch: false)

            // Agent attachment comments.
            let agentComments = "/internal/agent-api/attachments/\(linked)/comments"
            try await call("agent-comments", .get, agentComments, token: agentKey)
            try await call("agent-comments-unauth", .get, agentComments)
            try await call("agent-comments-noscope", .get, agentComments, token: writeOnlyKey)
            try await call("agent-comments-notfound", .get, "/internal/agent-api/attachments/nope/comments", token: agentKey)
            try await call("agent-comment-create", .post, agentComments, token: agentKey)
            try await call("agent-comment-create-unauth", .post, agentComments)
            try await call("agent-comment-create-baduuid", .post, "/internal/agent-api/attachments/nope/comments", token: agentKey)

            // Agent integration apps.
            let apps = "/internal/agent-api/integrations"
            try await call("app-list", .get, "\(apps)/app", token: agentKey)
            try await call("app-list-unauth", .get, "\(apps)/app")
            try await call("app-list-noscope", .get, "\(apps)/app", token: writeOnlyKey)
            try await call("app-status", .get, "\(apps)/app/status?client=local-app", token: agentKey)
            try await call("app-status-card", .get, "\(apps)/app/status?card=abc", token: agentKey)
            try await call("app-status-both", .get, "\(apps)/app/status?card=abc&client=local-app", token: agentKey)
            try await call("app-status-none", .get, "\(apps)/app/status", token: agentKey)
            try await call("app-status-unknown", .get, "\(apps)/app/status?client=nope", token: agentKey)
            try await call("app-update-nokey", .post, "\(apps)/app/update", token: agentKey, body: "{}")
            try await call("app-update-unknown", .post, "\(apps)/app/update", token: agentKey, body: "{\"clientKey\":\"nope\"}")
            try await call("app-update-unauth", .post, "\(apps)/app/update", body: "{}")
            try await call("app-update-multiline", .post, "\(apps)/app/update", token: agentKey, body: "{\"clientKey\":\"local-app\",\"whenToUse\":\"a\\nb\"}")
            try await call("app-update-long", .post, "\(apps)/app/update", token: agentKey, body: "{\"clientKey\":\"local-app\",\"whenToUse\":\"\(huge)\"}")
            try await call("app-update-bare", .post, "\(apps)/app/update", token: agentKey, body: "{\"clientKey\":\"local-app\",\"whenToUse\":\"use @scope/pkg\"}")
            try await call("app-update-badurl", .post, "\(apps)/app/update", token: agentKey, body: "{\"clientKey\":\"local-app\",\"setupUrl\":\"http://evil.example.test\"}")
            try await call("app-update", .post, "\(apps)/app/update", token: agentKey, body: "{\"clientKey\":\"local-app\",\"whenToUse\":\"  use / me  \",\"setupUrl\":\"https://local.example.test/setup\",\"setupDescription\":\"Do \\\"it\\\"\"}")
            try await call("app-update-clear", .post, "\(apps)/app/update", token: agentKey, body: "{\"clientKey\":\"local-app\",\"whenToUse\":null}", json: false)
            try await call("app-list-after", .get, "\(apps)/app", token: agentKey)
            try await call("app-status-after", .get, "\(apps)/app/status?client=local-app", token: agentKey)
            try await call("market", .get, "\(apps)/marketplace", token: agentKey)
            try await call("market-query", .get, "\(apps)/marketplace?query=pub&limit=1", token: agentKey)
            try await call("market-badlimit", .get, "\(apps)/marketplace?limit=0", token: agentKey)
            try await call("market-unauth", .get, "\(apps)/marketplace")
            try await call("login-unauth", .post, "\(apps)/login", body: "{}")
            try await call("login-nobody", .post, "\(apps)/login", token: agentKey, body: "[1]")
            try await call("login-unknown", .post, "\(apps)/login", token: agentKey, body: "{\"service\":\"nope\"}")
            try await call("login-badscope", .post, "\(apps)/login", token: agentKey, body: "{\"service\":\"local-app\",\"scopes\":[\"bogus\"]}")
            try await call("login-first", .post, "\(apps)/login", token: agentKey, body: "{\"service\":\"local-app\"}")
            try await call("login-again", .post, "\(apps)/login", token: agentKey, body: "{\"service\":\"local-app\",\"scopes\":[\"openid\"]}", json: false)
            try await call("login-install-required", .post, "\(apps)/login", token: agentKey, body: "{\"service\":\"pub-app\"}")
            try await call("login-install-target", .post, "\(apps)/login", token: agentKey, body: "{\"service\":\"pub-app\",\"target\":\"#nope-channel\"}")

            // Agent message lookups.
            let msg = "/internal/agent-api/messages"
            try await call("deliveries", .get, "\(msg)/\(agentMessage)/mention-deliveries", token: agentKey)
            try await call("deliveries-unknown", .get, "\(msg)/nope/mention-deliveries", token: agentKey)
            try await call("deliveries-unauth", .get, "\(msg)/\(agentMessage)/mention-deliveries")
            try await call("deliveries-noscope", .get, "\(msg)/\(agentMessage)/mention-deliveries", token: writeOnlyKey)
            try await call("resolve", .get, "\(msg)/\(agentMessage)/resolve", token: agentKey)
            try await call("resolve-ambiguous", .get, "\(msg)/aaaaaaaa/resolve", token: agentKey)
            try await call("resolve-unknown", .get, "\(msg)/nope/resolve", token: agentKey)
            try await call("resolve-quote", .get, "\(msg)/a%22b/resolve", token: agentKey)
            try await call("resolve-unauth", .get, "\(msg)/\(agentMessage)/resolve")
            try await call("resolve-noscope", .get, "\(msg)/\(agentMessage)/resolve", token: writeOnlyKey)
            let comment = accounts.humanMessageCount
            _ = comment
        }
    }
    let rendered = lines.joined(separator: "\n")
    let expected = integrationsAndAppAccessGolden
    if rendered != expected {
        print("GOLDEN-BEGIN\n\(rendered)\nGOLDEN-END")
    }
    #expect(rendered == expected)
}
