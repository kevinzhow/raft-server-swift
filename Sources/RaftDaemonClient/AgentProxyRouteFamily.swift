import Foundation

/// Content-free route family for the agent credential proxy: a closed mapping
/// from the internal agent-api pathname to a bounded family label. Ordering
/// matters — the comments-specific match sits above the generic attachments
/// match. Ported from the upstream daemon proxy.
public enum AgentProxyRouteFamily {
    static let agentAPI = "/internal/agent-api"

    public static func family(forPath pathname: String) -> String {
        if pathname == "\(agentAPI)/runtime-version" { return "runtime-version" }
        if pathname == "\(agentAPI)/v2/send" || pathname == "\(agentAPI)/send" { return "agent-api/send" }
        if pathname == "\(agentAPI)/events" { return "agent-api/events" }
        if pathname == "\(agentAPI)/inbox" || pathname.hasPrefix("\(agentAPI)/inbox/") { return "agent-api/inbox" }
        if pathname == "\(agentAPI)/receive-ack" { return "agent-api/events" }
        if pathname == "\(agentAPI)/tasks/claim" { return "tasks/claim" }
        if pathname == "\(agentAPI)/tasks/update-status" { return "tasks/update" }
        if pathname == "\(agentAPI)/tasks" || pathname.hasPrefix("\(agentAPI)/tasks/") { return "tasks" }
        if pathname.range(of: #"^/internal/agent-api/attachments/[^/]+/comments"#, options: .regularExpression) != nil {
            return "agent-api/attachments/comments"
        }
        if pathname.hasPrefix("\(agentAPI)/attachments/") { return "agent-api/attachments" }
        if pathname.range(of: #"^/internal/agent-api/messages/[^/]+/resolve$"#, options: .regularExpression) != nil {
            return "agent-api/messages/resolve"
        }
        if pathname.range(of: #"^/internal/agent-api/messages/[^/]+/reactions$"#, options: .regularExpression) != nil {
            return "agent-api/messages/reactions"
        }
        if pathname == "\(agentAPI)/server" { return "server" }
        if pathname.hasPrefix("\(agentAPI)/history") { return "agent-api/events" }
        if pathname.hasPrefix("\(agentAPI)/search") { return "agent-api/events" }
        if pathname.hasPrefix("\(agentAPI)/channel-members") { return "channel-members" }
        if pathname.hasPrefix("\(agentAPI)/knowledge") { return "knowledge" }
        if pathname == "\(agentAPI)/profile" || pathname.hasPrefix("\(agentAPI)/profile/") { return "profile" }
        if pathname == "\(agentAPI)/integrations" || pathname.hasPrefix("\(agentAPI)/integrations/") { return "integrations" }
        if pathname == "\(agentAPI)/upload" { return "attachments/upload" }
        if pathname == "\(agentAPI)/resolve-channel" { return "resolve-channel" }
        if pathname == "\(agentAPI)/threads" { return "threads" }
        if pathname == "\(agentAPI)/threads/unfollow" { return "threads/unfollow" }
        if pathname == "\(agentAPI)/prepare-action" { return "action/prepare" }
        if pathname == "\(agentAPI)/reminders" || pathname.hasPrefix("\(agentAPI)/reminders/") { return "reminders" }
        if pathname.range(of: #"^/internal/agent-api/channels/[^/]+/join$"#, options: .regularExpression) != nil {
            return "channels/join"
        }
        if pathname.range(of: #"^/internal/agent-api/channels/[^/]+/leave$"#, options: .regularExpression) != nil {
            return "channels/leave"
        }
        return "unknown"
    }
}
