import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

@Test func feedbackTransportUsesDirectFlagsAndReadsConversationSettingsAfterConstruction() throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111651"
    accounts.addAccount(id: userId, email: "feedback-unverified@slock.test", password: "password123")
    let transport = accounts.feedbackTransport
    let root = Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    accounts.setHandsFeedbackLegacyEnvironmentForTesting([
        "HANDS_FEEDBACK_BASE_URL": "https://hands.test",
        "HANDS_FEEDBACK_APP_SLUG": "legacy-app",
        "HANDS_FEEDBACK_APP_ID": "11111111-1111-4111-8111-111111111111",
        "HANDS_FEEDBACK_APP_TOKEN": "legacy-token",
    ])
    accounts.setHandsFeedbackAppsForTesting("{\"shared\":{\"reporter_id_secret\":\"secret\",\"route_subject_root\":\"\(root)\",\"cursor_secret\":\"cursor\"},\"android\":{\"app_slug\":\"android-app\",\"app_id\":\"a48a84f8-04ed-4db3-9297-189a14a36afc\",\"reporter_integration_id\":\"a7df6737-1452-4680-a23a-c321277f53f4\",\"credential_revision\":\"1\",\"client_key\":\"key\",\"token\":\"token\"}}")
    accounts.createFeatureFlagForTesting(key: FeedbackService.productFeedbackMultiAppFlag, defaultEnabled: true)
    let multi = try transport.routeEnvironment(source: "android", userId: userId)
    #expect(multi.isMultiApp)
    #expect(multi.appSlug == "android-app")
    accounts.setFeatureFlagKillSwitchForTesting(key: FeedbackService.productFeedbackMultiAppFlag, killSwitch: true)
    accounts.setHandsConversationForTesting(enabled: true, appToken: "later-conversation-token")
    let legacy = try transport.routeEnvironment(source: "android", userId: userId)
    #expect(!legacy.isMultiApp)
    #expect(legacy.appSlug == "legacy-app")
    #expect(legacy.conversationSessionEnabled)
    #expect(legacy.conversationToken == "later-conversation-token")
}
