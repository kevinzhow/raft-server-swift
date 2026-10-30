import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func shareArtifactCreationAndPublicPageAndPNG() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111322"
    let guestId = "11111111-1111-4111-8111-111111111323"
    let serverId = "33333333-3333-4333-8333-333333333491"
    accounts.addAccount(id: ownerId, email: "share-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: guestId, email: "share-guest@slock.test", password: "password123")
    accounts.markEmailVerified(userId: guestId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "share", name: "Share Server", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "general", creatorUserId: ownerId)

    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=") ?? Data()
    let boundary = "share-boundary"
    let form = "--\(boundary)\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n\(channelId)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"raft-thread.png\"\r\nContent-Type: image/png\r\n\r\n"
    let formTail = "\r\n--\(boundary)--\r\n"

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
                fields[.contentType] = "multipart/form-data; boundary=\(boundary)"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("share-owner@slock.test")
            let guestToken = try await login("share-guest@slock.test")

            var bodyData = Data(form.utf8)
            bodyData.append(png)
            bodyData.append(Data(formTail.utf8))

            let denied = try await client.send(.post, headers: headers(guestToken), to: "/api/share-artifacts/message-selection") { request in
                request.body = .init(data: bodyData)
            }
            #expect(denied.status == .forbidden)

            let created = try await client.send(.post, headers: headers(ownerToken), to: "/api/share-artifacts/message-selection") { request in
                request.body = .init(data: bodyData)
            }
            #expect(created.status == .ok)
            let createdBody = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any]
            let url = createdBody?["url"] as? String ?? ""
            let imageUrl = createdBody?["imageUrl"] as? String ?? ""
            #expect(url.hasSuffix("/share/\(createdBody?["id"] as? String ?? "")"))
            #expect(imageUrl.hasSuffix(".png"))

            let urlPath = URLComponents(string: url)?.path ?? url
            let page = try await client.send(.get, headers: HTTPFields(), to: URI(string: urlPath))
            #expect(page.status == .ok)
            #expect(page.headers[.contentType]?.contains("text/html") == true)
            #expect(page.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            let html = page.body.string ?? ""
            #expect(html.contains("name=\"robots\" content=\"noindex, nofollow\""))
            #expect(html.contains("name=\"twitter:card\" content=\"summary_large_image\""))
            #expect(html.contains("name=\"twitter:image\" content=\"\(imageUrl)\""))
            #expect(html.contains("property=\"og:image:width\" content=\"1\""))
            #expect(html.contains("property=\"og:image:height\" content=\"1\""))
            #expect(html.contains("name=\"twitter:image:alt\" content=\"Slock conversation screenshot\""))
            #expect(html.contains(".share-card { width: min(100%, 960px); margin-inline: auto; }"))
            #expect(html.contains("<div class=\"share-card\">"))

            let imagePath = URLComponents(string: imageUrl)?.path ?? imageUrl
            let image = try await client.send(.get, headers: HTTPFields(), to: URI(string: imagePath))
            #expect(image.status == .ok)
            #expect(image.headers[.contentType] == "image/png")
            #expect(image.headers[HTTPField.Name("Cache-Control")!] == "public, immutable, max-age=31536000")
            #expect(image.body.data == png)

            let malformed = try await client.send(.get, headers: HTTPFields(), to: "/share/not-a-uuid")
            #expect(malformed.status == .notFound)
            let malformedPNG = try await client.send(.get, headers: HTTPFields(), to: "/share/not-a-uuid.png")
            #expect(malformedPNG.status == .notFound)
        }
    }
}
