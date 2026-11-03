import Testing
import RaftDaemonClient

@Test func classifiesAttachmentCommentsAheadOfGenericAttachments() {
    #expect(AgentProxyRouteFamily.family(forPath: "/internal/agent-api/attachments/00000000-0000-4000-8000-000000000001/comments") == "agent-api/attachments/comments")
    #expect(AgentProxyRouteFamily.family(forPath: "/internal/agent-api/attachments/00000000-0000-4000-8000-000000000001") == "agent-api/attachments")
}

@Test func classifiesThreadListSeparatelyFromThreadUnfollow() {
    #expect(AgentProxyRouteFamily.family(forPath: "/internal/agent-api/threads") == "threads")
    #expect(AgentProxyRouteFamily.family(forPath: "/internal/agent-api/threads/unfollow") == "threads/unfollow")
    #expect(AgentProxyRouteFamily.family(forPath: "/internal/agent-api/tasks/claim") == "tasks/claim")
    #expect(AgentProxyRouteFamily.family(forPath: "/internal/agent-api/unknown") == "unknown")
}
