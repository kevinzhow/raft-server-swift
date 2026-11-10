import Foundation

/// Persistence-only DTOs; shared business records do not acquire Codable.
enum RuntimePersistenceMachineRows {
    struct MachineRow: Codable, Sendable {
        let id: String
        let serverId: String
        let userId: String
        let name: String
        let description: RuntimePersistenceNullable<String>
        let apiKey: RuntimePersistenceNullable<String>
        let apiKeyFingerprint: RuntimePersistenceNullable<String>
        let legacyKeyMigratedAt: RuntimePersistenceNullable<Date>
        let hostname: RuntimePersistenceNullable<String>
        let lastSeenAt: RuntimePersistenceNullable<Date>
        let runtimes: [String]
        // Optional decode preserves pre-inventory snapshot compatibility.
        let runtimeVersions: [String: String]?
        let runtimeDetection: MachineRuntimeDetectionFact?

        init(_ row: MachineRecord) {
            id = row.id
            serverId = row.serverId
            userId = row.userId
            name = row.name
            description = .init(row.description)
            apiKey = .init(row.apiKey)
            apiKeyFingerprint = .init(row.apiKeyFingerprint)
            legacyKeyMigratedAt = .init(row.legacyKeyMigratedAt)
            hostname = .init(row.hostname)
            lastSeenAt = .init(row.lastSeenAt)
            runtimes = row.runtimes
            runtimeVersions = row.runtimeVersions
            runtimeDetection = row.runtimeDetection
        }

        var record: MachineRecord {
            MachineRecord(
                id: id,
                serverId: serverId,
                userId: userId,
                name: name,
                description: description.value,
                apiKey: apiKey.value,
                apiKeyFingerprint: apiKeyFingerprint.value,
                legacyKeyMigratedAt: legacyKeyMigratedAt.value,
                hostname: hostname.value,
                lastSeenAt: lastSeenAt.value,
                runtimes: runtimes,
                runtimeVersions: runtimeVersions ?? [:],
                runtimeDetection: runtimeDetection
            )
        }
    }

    struct AttachedRow: Codable, Sendable {
        let id: String
        let serverId: String
        let userId: String
        let name: String
        let apiKey: String

        init(_ row: AttachedComputer) {
            id = row.id
            serverId = row.serverId
            userId = row.userId
            name = row.name
            apiKey = row.apiKey
        }

        var record: AttachedComputer {
            AttachedComputer(
                id: id,
                serverId: serverId,
                userId: userId,
                name: name,
                apiKey: apiKey
            )
        }
    }

    struct ComputerRow: Codable, Sendable {
        let id: String
        let serverId: String
        let name: String
        let apiKey: String
        let machineId: RuntimePersistenceNullable<String>
        let revokedAt: RuntimePersistenceNullable<Date>
        let version: RuntimePersistenceNullable<String>

        init(_ row: (id: String, serverId: String, name: String, apiKey: String, machineId: String?, revokedAt: Date?, online: Bool, version: String?)) {
            id = row.id
            serverId = row.serverId
            name = row.name
            apiKey = row.apiKey
            machineId = .init(row.machineId)
            revokedAt = .init(row.revokedAt)
            version = .init(row.version)
        }

        var record: (id: String, serverId: String, name: String, apiKey: String, machineId: String?, revokedAt: Date?, online: Bool, version: String?) {
            (
                id: id,
                serverId: serverId,
                name: name,
                apiKey: apiKey,
                machineId: machineId.value,
                revokedAt: revokedAt.value,
                online: false,
                version: version.value
            )
        }
    }

    struct DetectionRow: Codable, Sendable {
        let status: String
        let unfinished: Set<String>

        init(_ row: (status: String, unfinished: Set<String>)) {
            status = row.status
            unfinished = row.unfinished
        }

        var record: (status: String, unfinished: Set<String>) {
            (
                status: status,
                unfinished: unfinished
            )
        }
    }

    struct ModelRow: Codable, Sendable {
        let id: String
        let label: String

        init(_ row: (id: String, label: String)) {
            id = row.id
            label = row.label
        }

        var record: (id: String, label: String) {
            (
                id: id,
                label: label
            )
        }
    }

    struct ModelsRow: Codable, Sendable {
        let models: [ModelRow]
        let updatedAt: Date

        init(_ row: (models: [(id: String, label: String)], updatedAt: Date)) {
            models = row.models.map(ModelRow.init)
            updatedAt = row.updatedAt
        }

        var record: (models: [(id: String, label: String)], updatedAt: Date) {
            (
                models: models.map { $0.record },
                updatedAt: updatedAt
            )
        }
    }

    struct UsageRow: Codable, Sendable {
        let json: String
        let staleAfter: Date

        init(_ row: (json: String, staleAfter: Date)) {
            json = row.json
            staleAfter = row.staleAfter
        }

        var record: (json: String, staleAfter: Date) {
            (
                json: json,
                staleAfter: staleAfter
            )
        }
    }

    struct KeyRow: Codable, Sendable {
        let serverId: String
        let agentId: String

        init(_ row: (serverId: String, agentId: String)) {
            serverId = row.serverId
            agentId = row.agentId
        }

        var record: (serverId: String, agentId: String) {
            (
                serverId: serverId,
                agentId: agentId
            )
        }
    }

    struct ReleaseRow: Codable, Sendable {
        let version: String
        let notesJSON: String

        init(_ row: (version: String, notesJSON: String)) {
            version = row.version
            notesJSON = row.notesJSON
        }

        var record: (version: String, notesJSON: String) {
            (
                version: version,
                notesJSON: notesJSON
            )
        }
    }
}
