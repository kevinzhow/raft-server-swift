import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func feedbackCompositionKeepsLiveConfigurationAttributionAndWarningCallbacks() async throws {
    let first = try FakeHands(status: 201, responseBody: #"{"id":"first-provider","status":"open","attachments":0}"#)
    defer { first.stop() }
    let second = try FakeHands(status: 201, responseBody: #"{"id":"second-provider","status":"open","attachments":0}"#)
    defer { second.stop() }
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111650"
    let serverId = "33333333-3333-4333-8333-333333333673"
    accounts.addAccount(id: userId, email: "feedback-composition@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "feedback-composition", name: "Feedback Composition", ownerId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    accounts.createFeatureFlagForTesting(key: FeedbackService.productFeedbackMultiAppFlag, defaultEnabled: false)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func submit(server: String? = nil, clientKind: String? = nil) async throws -> ClientResponse {
                let boundary = "feedback-composition-boundary"
                let metadata = clientKind == nil ? #"{"browser":"spoofed-browser","userId":"spoofed-user"}"# : #"{"client_kind":"android","platform":"android","client_version":"1.0.0"}"#
                let fields = [("type", "idea"), ("message", "Composition sends to the current provider."),
                    ("submission_id", UUID().uuidString.lowercased()), ("metadata", metadata)]
                let payload = fields.map { "--\(boundary)\r\nContent-Disposition: form-data; name=\"\($0.0)\"\r\n\r\n\($0.1)\r\n" }.joined() + "--\(boundary)--\r\n"
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
                if let clientKind { headers[HTTPField.Name("X-Raft-Client-Kind")!] = clientKind }
                headers[HTTPField.Name("X-Server-Id")!] = server ?? serverId
                return try await client.send(.post, headers: headers, to: "/api/product-feedback") { $0.body = .init(string: payload) }
            }
            accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(first.port)", appId: "raft-web", appToken: "first-token", appSlug: "first-app")
            let initial = try await submit()
            #expect(initial.status == .created)
            #expect(initial.body.string?.contains("first-provider") == true)
            let initialWire = try #require(first.requests().last)
            #expect(initialWire.path == "/public/v2/apps/first-app/feedback")
            #expect(initialWire.body.contains("reporter_attribution"))
            #expect(initialWire.body.contains("feedback-composition"))
            #expect(initialWire.body.contains(userId))
            #expect(!initialWire.body.contains("spoofed-browser"))
            #expect(!initialWire.body.contains("spoofed-user"))

            accounts.oauth.removeMember(serverId: serverId, userId: userId)
            #expect(try await submit().status == .created)
            #expect(first.requests().last?.body.contains("reporter_attribution") == false)
            #expect(try await submit(server: "not-a-uuid").status == .created)
            #expect(first.requests().last?.body.contains("reporter_attribution") == false)

            accounts.setHandsFeedbackAppsForTesting("invalid-apps-json")
            accounts.setFeatureFlagDefaultForTesting(key: FeedbackService.productFeedbackMultiAppFlag, defaultEnabled: true)
            accounts.setHandsFeedbackWarningSinkForTesting { _ in
                // Reenter the warning owner; the current callback must run after its borrow ends.
                accounts.setHandsFeedbackWarningSinkForTesting(nil)
                accounts.setFeatureFlagDefaultForTesting(key: FeedbackService.productFeedbackMultiAppFlag, defaultEnabled: false)
                accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(second.port)", appId: "raft-web", appToken: "second-token", appSlug: "second-app")
            }
            let unavailable = try await submit(clientKind: "android")
            #expect(unavailable.status == .serviceUnavailable)
            #expect(unavailable.body.string?.contains("feedback_integration_unavailable") == true)
            let recovered = try await submit()
            #expect(recovered.status == .created)
            #expect(recovered.body.string?.contains("second-provider") == true)
            #expect(second.requests().last?.path == "/public/v2/apps/second-app/feedback")

            accounts.setFeatureFlagDefaultForTesting(key: FeedbackService.productFeedbackMultiAppFlag, defaultEnabled: true)
            accounts.setHandsFeedbackWarningSinkForTesting { _ in
                accounts.setHandsFeedbackWarningSinkForTesting(nil)
                accounts.setFeatureFlagDefaultForTesting(key: FeedbackService.productFeedbackMultiAppFlag, defaultEnabled: false)
                accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(first.port)", appId: "raft-web", appToken: "replacement-token", appSlug: "replacement-app")
            }
            #expect(try await submit(clientKind: "android").status == .serviceUnavailable)
            #expect(try await submit().status == .created)
            #expect(first.requests().last?.path == "/public/v2/apps/replacement-app/feedback")
        }
    }
}

@Test func oneFeedbackSubmissionInstanceReadsLaterProvidersAndWarningSinks() async throws {
    let first = try FakeHands(status: 201, responseBody: #"{"id":"stored-first","status":"open"}"#)
    defer { first.stop() }
    let second = try FakeHands(status: 201, responseBody: #"{"id":"stored-second","status":"open"}"#)
    defer { second.stop() }
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111652"
    accounts.addAccount(id: userId, email: "feedback-stored@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let token = accounts.mintAccessTokenForTesting(userId: userId)
    let submissions = accounts.productFeedbackSubmissions
    func request(native: Bool = false) -> ProductFeedbackSubmissionRequest {
        let boundary = "stored-feedback-boundary"
        var fields = [("type", "idea"), ("message", "Current provider."), ("submission_id", UUID().uuidString.lowercased())]
        if native { fields.append(("metadata", #"{"client_kind":"android","platform":"android","client_version":"1.0.0"}"#)) }
        let body = fields.map { "--\(boundary)\r\nContent-Disposition: form-data; name=\"\($0.0)\"\r\n\r\n\($0.1)\r\n" }.joined() + "--\(boundary)--\r\n"
        return ProductFeedbackSubmissionRequest(authorization: "Bearer \(token)", contentType: "multipart/form-data; boundary=\(boundary)", body: body, clientKindHeader: native ? "android" : "")
    }
    accounts.createFeatureFlagForTesting(key: FeedbackService.productFeedbackMultiAppFlag, defaultEnabled: false)
    accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(first.port)", appId: "raft-web", appToken: "first", appSlug: "stored-first-app")
    #expect(try await submissions.submit(request()).id == "stored-first")
    accounts.setHandsFeedbackAppsForTesting("invalid-apps-json")
    accounts.setFeatureFlagDefaultForTesting(key: FeedbackService.productFeedbackMultiAppFlag, defaultEnabled: true)
    accounts.setHandsFeedbackWarningSinkForTesting { _ in
        accounts.setHandsFeedbackWarningSinkForTesting(nil)
        accounts.setFeatureFlagDefaultForTesting(key: FeedbackService.productFeedbackMultiAppFlag, defaultEnabled: false)
        accounts.setHandsFeedbackForTesting(baseURL: "http://127.0.0.1:\(second.port)", appId: "raft-web", appToken: "second", appSlug: "stored-second-app")
    }
    do {
        _ = try await submissions.submit(request(native: true))
        Issue.record("The enabled multi-app route must reject the invalid app configuration")
    } catch let error as ProductFeedbackSubmissionError {
        #expect(error.status == 503)
        #expect(error.errorCode == "feedback_integration_unavailable")
    }
    #expect(try await submissions.submit(request()).id == "stored-second")
    #expect(first.requests().last?.path == "/public/v2/apps/stored-first-app/feedback")
    #expect(second.requests().last?.path == "/public/v2/apps/stored-second-app/feedback")
}
