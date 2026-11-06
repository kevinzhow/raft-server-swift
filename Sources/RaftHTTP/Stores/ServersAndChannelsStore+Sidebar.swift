import Foundation

extension ServersAndChannelsStore {
    // MARK: - Sidebar order

    /// One sidebar sort-mode row.
    struct SidebarModesRow: Sendable, Equatable {
        var channel: String
        var joint: String
        var dm: String
        var pinned: String
        var channelTabs: [String]
        var agentTabs: [String]

        static let defaults = SidebarModesRow(
            channel: "manual",
            joint: "manual",
            dm: "manual",
            pinned: "manual",
            channelTabs: ["chat"],
            agentTabs: ["activity", "profile"]
        )
    }

    struct SidebarSectionRow: Sendable, Equatable {
        var id: String
        var name: String
        var emoji: String?
        var sortMode: String
    }

    struct SidebarPlacementRow: Sendable, Equatable {
        var kind: String
        var id: String
        var sectionId: String
        var position: Int
    }

    struct SidebarSectionsRow: Sendable, Equatable {
        var sections: [SidebarSectionRow]
        var order: [String]
        var placements: [SidebarPlacementRow]
        var version: Int

        /// The retired handler's first-read default: no custom sections and the
        /// four system sections in their published order.
        static let defaults = SidebarSectionsRow(
            sections: [],
            order: ["system:pinned", "system:joint", "system:channels", "system:dms"],
            placements: [],
            version: 0
        )
    }

    struct SidebarPinRow: Sendable, Equatable {
        var kind: String
        var id: String
    }

    struct SidebarPinnedRow: Sendable, Equatable {
        var refs: [SidebarPinRow]
        var channelIds: [String]
        var agentIds: [String]
        var version: Int
    }

    /// The three sidebar rows one request reads; `pinned` is nil when the
    /// caller has never written the pinned ledger.
    struct SidebarSnapshot: Sendable, Equatable {
        var modes: SidebarModesRow
        var sections: SidebarSectionsRow
        var pinned: SidebarPinnedRow?
    }

    enum SidebarApplyResult: Sendable, Equatable {
        case applied
        case sectionsConflict(currentVersion: Int)
    }

    /// One locked read of the three sidebar rows the legacy handler read under
    /// the directory lock.
    func sidebarSnapshot(serverId: String, userId: String) -> SidebarSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(serverId)\n\(userId)"
        let modes = storage.sidebarModes[key].map {
            SidebarModesRow(
                channel: $0.channel,
                joint: $0.joint,
                dm: $0.dm,
                pinned: $0.pinned,
                channelTabs: $0.channelTabs,
                agentTabs: $0.agentTabs
            )
        } ?? .defaults
        let sections = storage.sidebarSections[key].map {
            SidebarSectionsRow(
                sections: $0.sections.map {
                    SidebarSectionRow(id: $0.id, name: $0.name, emoji: $0.emoji, sortMode: $0.sortMode)
                },
                order: $0.order,
                placements: $0.placements.map {
                    SidebarPlacementRow(kind: $0.kind, id: $0.id, sectionId: $0.sectionId, position: $0.position)
                },
                version: $0.version
            )
        } ?? .defaults
        let pinned = storage.sidebarPinnedRefs[key].map {
            SidebarPinnedRow(
                refs: $0.refs.map { SidebarPinRow(kind: $0.kind, id: $0.id) },
                channelIds: $0.channelIds,
                agentIds: $0.agentIds,
                version: $0.version
            )
        }
        return SidebarSnapshot(modes: modes, sections: sections, pinned: pinned)
    }

    /// The sidebar write: the version check and every row write happen in one
    /// critical section, so two concurrent patches cannot both accept the same
    /// `sectionsVersion`.
    func applySidebarOrder(
        serverId: String,
        userId: String,
        modes: SidebarModesRow,
        sections: SidebarSectionsRow?,
        pinned: SidebarPinnedRow?,
        expectedSectionsVersion: Int?
    ) -> SidebarApplyResult {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(serverId)\n\(userId)"
        if let expectedSectionsVersion {
            let current = storage.sidebarSections[key]?.version ?? 0
            guard current == expectedSectionsVersion else {
                return .sectionsConflict(currentVersion: current)
            }
        }
        storage.sidebarModes[key] = (
            channel: modes.channel,
            joint: modes.joint,
            dm: modes.dm,
            pinned: modes.pinned,
            channelTabs: modes.channelTabs,
            agentTabs: modes.agentTabs
        )
        if let sections {
            storage.sidebarSections[key] = (
                sections: sections.sections.map { ($0.id, $0.name, $0.emoji, $0.sortMode) },
                order: sections.order,
                placements: sections.placements.map { ($0.kind, $0.id, $0.sectionId, $0.position) },
                version: sections.version
            )
        }
        if let pinned {
            storage.sidebarPinnedRefs[key] = (
                refs: pinned.refs.map { ($0.kind, $0.id) },
                channelIds: pinned.channelIds,
                agentIds: pinned.agentIds,
                version: pinned.version
            )
        }
        return .applied
    }
}
