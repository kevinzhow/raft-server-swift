import Foundation

/// The published `dm:@…` target refusals.
///
/// These replies belong to the execute/send domains, which still return
/// `HTTPReply` while they live on `EmailLoginDirectory`. Keeping the projection
/// here means the action-card prepare service file carries no HTTP type, and
/// the published bodies keep their legacy member order.
func dmPeerFailureReply(_ resolution: DMPeerResolution) -> HTTPReply? {
    switch resolution {
    case .ambiguous(let name):
        return EmailLoginDirectory.json(
            409,
            "{\"error\":\"More than one DM peer is named \(name). Address it as dm:@\(name)~agent or dm:@\(name)~human.\",\"code\":\"DM_TARGET_AMBIGUOUS\",\"suggestedNextAction\":\"Retry with dm:@\(name)~agent for the agent or dm:@\(name)~human for the human.\"}"
        )
    case .invalidKind(let kind, _):
        return EmailLoginDirectory.json(
            400,
            "{\"error\":\"Unknown DM peer kind \(kind).\",\"code\":\"DM_TARGET_INVALID_PEER_KIND\",\"suggestedNextAction\":\"Use dm:@<name>~human or dm:@<name>~agent.\"}"
        )
    case .notFound:
        return EmailLoginDirectory.json(404, "{\"error\":\"Channel not found or not visible\"}")
    case .resolved:
        return nil
    }
}
