import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    public struct SidebarOrder: Sendable {
        public var channelOrder: [String]
        public var agentOrder: [String]
        public var dmOrder: [String]
        public var pinnedOrder: [String]
        public var hiddenDmIds: [String]

        public init(
            channelOrder: [String] = [],
            agentOrder: [String] = [],
            dmOrder: [String] = [],
            pinnedOrder: [String] = [],
            hiddenDmIds: [String] = []
        ) {
            self.channelOrder = channelOrder
            self.agentOrder = agentOrder
            self.dmOrder = dmOrder
            self.pinnedOrder = pinnedOrder
            self.hiddenDmIds = hiddenDmIds
        }
    }
    public func setSidebarOrder(serverId: String, userId: String, order: SidebarOrder) {
        lock.lock()
        sidebarOrders["\(serverId)\n\(userId)"] = order
        lock.unlock()
    }

    public func sanitizedSidebarOrder(serverId: String, userId: String) -> SidebarOrder {
        lock.lock()
        defer { lock.unlock() }
        let stored = sidebarOrders["\(serverId)\n\(userId)"] ?? SidebarOrder()
        func isUUID(_ value: String) -> Bool {
            value.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil
        }
        let channelIds = Set(channelRecords.filter { $0.serverId == serverId && $0.type != "dm" && $0.type != "thread" }.map { $0.id })
        let agentIds = Set(agents.values.filter { $0.serverId == serverId && !$0.deleted }.map { $0.id })
        let dmIds = Set(channelRecords.filter {
            $0.serverId == serverId && $0.type == "dm" && channelHumans.contains("\($0.id)\n\(userId)")
        }.map { $0.id })
        func keep(_ ids: [String], in allowed: Set<String>) -> [String] {
            ids.filter { isUUID($0) && allowed.contains($0) }
        }
        let pinned = stored.pinnedOrder.filter { value in
            isUUID(value) && (channelIds.contains(value) || agentIds.contains(value) || dmIds.contains(value))
        }
        return SidebarOrder(
            channelOrder: keep(stored.channelOrder, in: channelIds),
            agentOrder: keep(stored.agentOrder, in: agentIds),
            dmOrder: keep(stored.dmOrder, in: dmIds),
            pinnedOrder: pinned,
            hiddenDmIds: keep(stored.hiddenDmIds, in: dmIds)
        )
    }
}
