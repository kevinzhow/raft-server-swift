import Foundation
import HTTPTypes
import Testing
@testable import RaftHTTP
@testable import RaftHTTPServer

@Test func humanAdmissionRouteScopeMatchesNodeMountsAndRouteLocalGates() {
    let verified: [(HTTPRequest.Method, String)] = [
        (.post, "/api/servers"), (.get, "/api/servers/id"), (.get, "/API/Servers/"),
        (.get, "/api/feature-flags"), (.get, "/api/channels/inbox"),
        (.post, "/api/read-mutations"), (.post, "/api/messages"), (.post, "/api/v2/messages"),
        (.get, "/api/agents/manageable"), (.post, "/api/agents/id/credentials"),
        (.get, "/api/agents/id/credentials"), (.delete, "/api/agents/id/credentials/credential"),
        (.get, "/api/raftbench"), (.get, "/api/agents"), (.post, "/api/billing"),
        (.post, "/api/tasks"), (.post, "/api/reminders"), (.post, "/api/share-artifacts"),
        (.post, "/api/integration-invites"), (.get, "/api/integrations"), (.post, "/api/actions"),
        (.post, "/api/product-events/batch"), (.get, "/api/mcp"), (.get, "/api/provider-connections"),
        (.get, "/api/agent-runtime-providers"), (.post, "/api/product-feedback"),
        (.post, "/api/message-translations:batch"), (.post, "/api/public/servers/example/join-as-guest"),
        (.post, "/api/slack-bridge/oauth/start"), (.get, "/api/slack-bridge/provisioning"),
        (.post, "/api/slack-bridge/provisioning/connect"), (.put, "/api/slack-bridge/provisioning/channel-pairs"),
        (.delete, "/api/slack-bridge/provisioning/channel-pairs"), (.post, "/api/slack-bridge/provisioning/disconnect"),
        (.post, "/api/slack-bridge/provisioning/preflight"), (.post, "/api/slack-bridge/provisioning/enable"),
        (.post, "/api/push/subscribe"), (.delete, "/api/push/subscribe"), (.get, "/api/push/delivery-status"),
        (.post, "/api/push/registrations"), (.delete, "/api/push/registrations/installation"), (.post, "/api/push/test"),
        (.post, "/api/notifications/enrollment-grants"), (.get, "/api/notifications/devices"),
        (.delete, "/api/notifications/devices/device"), (.get, "/api/announcements/active"),
        (.post, "/api/announcements/announcement/dismiss"),
        (.get, "/api/attachments/upload-capabilities"), (.post, "/api/attachments/upload-sessions"),
        (.get, "/api/attachments/upload-sessions/channel/active"),
        (.get, "/api/attachments/upload-sessions/11111111-1111-4111-8111-111111111111"),
        // An unmatched callback method must fall through to the later verified /api/mcp mount.
        (.post, "/api/mcp/oauth/callback"), (.get, "/api/mcp/oauth/unmatched"),
    ]
    for (method, path) in verified {
        #expect(HumanAdmissionPolicy.requirement(method: method, path: path) == .verifiedProfile)
    }
    #expect(HumanAdmissionPolicy.requirement(method: .post, path: "/api/auth/accept-invite") == .profileOnly)
    for path in ["/api/attachments/upload", "/api/attachments/comments/counts", "/api/attachments/attachment/comments"] {
        #expect(HumanAdmissionPolicy.requirement(method: .post, path: path) == .legacyAttachment)
    }
    #expect(HumanAdmissionPolicy.requirement(method: .get, path: "/api/attachments/comments/counts") == .legacyAttachment)
    #expect(HumanAdmissionPolicy.requirement(method: .get, path: "/api/attachments/attachment/comments") == .legacyAttachment)
}

@Test func humanAdmissionPreservesRecoveryMachineCallbacksPublicAndFlexAttachmentPolicies() {
    let exempt: [(HTTPRequest.Method, String)] = [
        (.post, "/api/auth/register"), (.post, "/api/auth/login"), (.get, "/api/auth/me"),
        (.post, "/api/auth/me/complete-profile"), (.post, "/api/auth/verify-email"),
        (.post, "/api/auth/forgot-password"), (.post, "/api/auth/reset-password"),
        (.post, "/api/computer/attach"), (.post, "/api/computer/adopt-legacy"),
        (.get, "/api/oauth/authorize"), (.get, "/api/slack-bridge/oauth/callback"),
        (.get, "/api/mcp/oauth/callback"), (.head, "/api/mcp/oauth/client-metadata"),
        (.get, "/api/connections/provider/callback"), (.get, "/api/public/servers/example"),
        (.post, "/api/public/servers/example/message-translations:batch"), (.get, "/api/public/feature-flags"),
        (.get, "/api/announcements/images/image"), (.post, "/api/push/family-revoke"),
        (.post, "/api/push/prompt-events"), (.post, "/api/notifications/enrollment-exchanges"),
        (.post, "/api/notifications/credentials/rotate"), (.get, "/api/notifications/stream"),
        (.get, "/api/attachments/attachment"), (.head, "/api/attachments/attachment/preview"),
        (.get, "/api/attachments/attachment/url"), (.get, "/api/attachments/attachment/html-preview"),
        (.get, "/api/attachments/attachment/html-preview-url"), (.post, "/api/attachments/urls"),
        (.post, "/internal/agent-api/send"), (.post, "/internal/machine/scope-attestation"),
        (.get, "/api/servers-lookalike"), (.post, "/api/auth/accept-invite-lookalike"),
        (.get, "/api/slack-bridge/provisioning-lookalike"), (.post, "/api/message-translations:batch/"),
        (.get, "/api//servers"), (.options, "/api/servers"),
    ]
    for (method, path) in exempt {
        #expect(HumanAdmissionPolicy.requirement(method: method, path: path) == nil)
    }
    #expect(HumanAdmissionPolicy.requirement(method: .get, path: "/api/notifications/devices", nativeNotificationsEnabled: false) == nil)
}
