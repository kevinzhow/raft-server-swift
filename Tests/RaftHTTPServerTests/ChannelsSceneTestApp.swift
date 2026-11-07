import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import TestSupport

/// Only production Channels routes; full-Fallback middleware is not mounted.
func makeChannelsSceneFeature(_ scene: ChannelsScene, realtime: RealtimeHub?) -> ChannelsFeature {
    let services = scene.services
    let messaging = services.channels.messaging.bindingUserDelivery(
        emitToUser: { userId, event, payload in
            realtime?.emit(room: "user:\(userId)", event: event, payloadJSON: payload)
        },
        joinUserSessions: { userId, room in
            realtime?.joinUserSessions(userId: userId, room: room)
        }
    )
    return ChannelsFeature(
        threads: services.channels.threads.bindingFollowersPublication(
            publishFollowersUpdated: messaging.publishThreadFollowers
        ),
        reactions: services.messaging.reactions,
        inbox: services.messaging.inbox,
        assignments: services.channels.assignments.bindingTaskPublication(publishTaskUpdated: { _ in }),
        readState: services.integrations.tools,
        membership: services.channels.membership,
        search: services.messaging.search,
        send: services.messaging.send,
        reminders: services.integrations.reminders,
        oauth: services.integrations.oauth,
        lifecycle: services.integrations.lifecycle,
        agentsLifecycle: services.agents.lifecycle,
        socketMembership: services.messaging.socketMembership,
        channelRoutes: services.integrations.channelRoutes,
        channelMessaging: messaging,
        realtime: realtime
    )
}
