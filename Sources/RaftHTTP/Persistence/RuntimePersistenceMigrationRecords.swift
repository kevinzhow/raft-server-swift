import Foundation

/// Persistence-only DTOs; shared business records do not acquire Codable.
enum RuntimePersistenceMigrationRows {
    struct ChunkRow: Codable, Sendable {
        let sha256: String
        let sizeBytes: Int

        init(_ row: (sha256: String, sizeBytes: Int)) {
            sha256 = row.sha256
            sizeBytes = row.sizeBytes
        }

        var record: (sha256: String, sizeBytes: Int) {
            (
                sha256: sha256,
                sizeBytes: sizeBytes
            )
        }
    }

    struct MachineMigrationRow: Codable, Sendable {
        let agentId: String
        let serverId: String
        let supportRef: String
        let revision: Int
        let state: String
        let sourceMachineId: String
        let targetMachineId: String
        let transportGeneration: String
        let transportProvider: String
        let transportSessionId: String
        let sourceTokenHash: String
        let targetTokenHash: String
        let manifestJSON: RuntimePersistenceNullable<String>
        let manifestChunks: [Int: ChunkRow]
        let chunkReceipts: [Int: String]
        let failureReason: RuntimePersistenceNullable<String>
        let transportErrorCode: RuntimePersistenceNullable<String>
        let transportErrorMessage: RuntimePersistenceNullable<String>
        let transportLostAt: RuntimePersistenceNullable<Date>
        let transportTeardownAt: RuntimePersistenceNullable<Date>
        let canceledAt: RuntimePersistenceNullable<Date>
        let cancelReason: RuntimePersistenceNullable<String>
        let cancelDispatchAttempts: Int
        let cancelLastDispatchAt: RuntimePersistenceNullable<Date>
        let cancelErrorCode: RuntimePersistenceNullable<String>
        let cancelGeneration: RuntimePersistenceNullable<String>
        let cancelTransportGeneration: RuntimePersistenceNullable<String>
        let cancelDisposition: RuntimePersistenceNullable<String>
        let cancelSourceAck: RuntimePersistenceNullable<String>
        let cancelTargetAck: RuntimePersistenceNullable<String>
        let cancelSourceAckAt: RuntimePersistenceNullable<Date>
        let cancelTargetAckAt: RuntimePersistenceNullable<Date>
        let quiesceReceiptJSON: RuntimePersistenceNullable<String>
        let progressJSON: RuntimePersistenceNullable<String>
        let previousTransportGeneration: RuntimePersistenceNullable<String>
        let flippedAt: RuntimePersistenceNullable<Date>
        let arrivedAt: RuntimePersistenceNullable<Date>
        let completedAt: RuntimePersistenceNullable<Date>
        let updatedAt: Date
        let sourceWorkspaceArchivedAt: RuntimePersistenceNullable<Date>
        let sourceWorkspaceArchiveAttempts: Int
        let sourceWorkspaceArchiveLastError: RuntimePersistenceNullable<String>
        let sourceWorkspaceArchiveRetryAt: RuntimePersistenceNullable<Date>
        let sourceWorkspaceArchiveAbandonedAt: RuntimePersistenceNullable<Date>
        let autoStartFailureStage: RuntimePersistenceNullable<String>
        let autoStartFailureCode: RuntimePersistenceNullable<String>
        let arrivalReportPath: RuntimePersistenceNullable<String>
        let arrivalReportSha256: RuntimePersistenceNullable<String>

        init(_ row: MachineMigrationRecord) {
            agentId = row.agentId
            serverId = row.serverId
            supportRef = row.supportRef
            revision = row.revision
            state = row.state
            sourceMachineId = row.sourceMachineId
            targetMachineId = row.targetMachineId
            transportGeneration = row.transportGeneration
            transportProvider = row.transportProvider
            transportSessionId = row.transportSessionId
            sourceTokenHash = row.sourceTokenHash
            targetTokenHash = row.targetTokenHash
            manifestJSON = .init(row.manifestJSON)
            manifestChunks = row.manifestChunks.mapValues(ChunkRow.init)
            chunkReceipts = row.chunkReceipts
            failureReason = .init(row.failureReason)
            transportErrorCode = .init(row.transportErrorCode)
            transportErrorMessage = .init(row.transportErrorMessage)
            transportLostAt = .init(row.transportLostAt)
            transportTeardownAt = .init(row.transportTeardownAt)
            canceledAt = .init(row.canceledAt)
            cancelReason = .init(row.cancelReason)
            cancelDispatchAttempts = row.cancelDispatchAttempts
            cancelLastDispatchAt = .init(row.cancelLastDispatchAt)
            cancelErrorCode = .init(row.cancelErrorCode)
            cancelGeneration = .init(row.cancelGeneration)
            cancelTransportGeneration = .init(row.cancelTransportGeneration)
            cancelDisposition = .init(row.cancelDisposition)
            cancelSourceAck = .init(row.cancelSourceAck)
            cancelTargetAck = .init(row.cancelTargetAck)
            cancelSourceAckAt = .init(row.cancelSourceAckAt)
            cancelTargetAckAt = .init(row.cancelTargetAckAt)
            quiesceReceiptJSON = .init(row.quiesceReceiptJSON)
            progressJSON = .init(row.progressJSON)
            previousTransportGeneration = .init(row.previousTransportGeneration)
            flippedAt = .init(row.flippedAt)
            arrivedAt = .init(row.arrivedAt)
            completedAt = .init(row.completedAt)
            updatedAt = row.updatedAt
            sourceWorkspaceArchivedAt = .init(row.sourceWorkspaceArchivedAt)
            sourceWorkspaceArchiveAttempts = row.sourceWorkspaceArchiveAttempts
            sourceWorkspaceArchiveLastError = .init(row.sourceWorkspaceArchiveLastError)
            sourceWorkspaceArchiveRetryAt = .init(row.sourceWorkspaceArchiveRetryAt)
            sourceWorkspaceArchiveAbandonedAt = .init(row.sourceWorkspaceArchiveAbandonedAt)
            autoStartFailureStage = .init(row.autoStartFailureStage)
            autoStartFailureCode = .init(row.autoStartFailureCode)
            arrivalReportPath = .init(row.arrivalReportPath)
            arrivalReportSha256 = .init(row.arrivalReportSha256)
        }

        var record: MachineMigrationRecord {
            MachineMigrationRecord(
                agentId: agentId,
                serverId: serverId,
                supportRef: supportRef,
                revision: revision,
                state: state,
                sourceMachineId: sourceMachineId,
                targetMachineId: targetMachineId,
                transportGeneration: transportGeneration,
                transportProvider: transportProvider,
                transportSessionId: transportSessionId,
                sourceTokenHash: sourceTokenHash,
                targetTokenHash: targetTokenHash,
                manifestJSON: manifestJSON.value,
                manifestChunks: manifestChunks.mapValues { $0.record },
                chunkReceipts: chunkReceipts,
                failureReason: failureReason.value,
                transportErrorCode: transportErrorCode.value,
                transportErrorMessage: transportErrorMessage.value,
                transportLostAt: transportLostAt.value,
                transportTeardownAt: transportTeardownAt.value,
                canceledAt: canceledAt.value,
                cancelReason: cancelReason.value,
                cancelDispatchAttempts: cancelDispatchAttempts,
                cancelLastDispatchAt: cancelLastDispatchAt.value,
                cancelErrorCode: cancelErrorCode.value,
                cancelGeneration: cancelGeneration.value,
                cancelTransportGeneration: cancelTransportGeneration.value,
                cancelDisposition: cancelDisposition.value,
                cancelSourceAck: cancelSourceAck.value,
                cancelTargetAck: cancelTargetAck.value,
                cancelSourceAckAt: cancelSourceAckAt.value,
                cancelTargetAckAt: cancelTargetAckAt.value,
                quiesceReceiptJSON: quiesceReceiptJSON.value,
                progressJSON: progressJSON.value,
                previousTransportGeneration: previousTransportGeneration.value,
                flippedAt: flippedAt.value,
                arrivedAt: arrivedAt.value,
                completedAt: completedAt.value,
                updatedAt: updatedAt,
                sourceWorkspaceArchivedAt: sourceWorkspaceArchivedAt.value,
                sourceWorkspaceArchiveAttempts: sourceWorkspaceArchiveAttempts,
                sourceWorkspaceArchiveLastError: sourceWorkspaceArchiveLastError.value,
                sourceWorkspaceArchiveRetryAt: sourceWorkspaceArchiveRetryAt.value,
                sourceWorkspaceArchiveAbandonedAt: sourceWorkspaceArchiveAbandonedAt.value,
                autoStartFailureStage: autoStartFailureStage.value,
                autoStartFailureCode: autoStartFailureCode.value,
                arrivalReportPath: arrivalReportPath.value,
                arrivalReportSha256: arrivalReportSha256.value
            )
        }
    }

    struct HostedMigrationRow: Codable, Sendable {
        let agentId: String
        let serverId: String
        let supportRef: String
        let revision: Int
        let state: String
        let sourceMachineId: RuntimePersistenceNullable<String>
        let canceledAt: RuntimePersistenceNullable<Date>
        let cancelReason: RuntimePersistenceNullable<String>
        let cancelDispatchAttempts: Int
        let cancelLastDispatchAt: RuntimePersistenceNullable<Date>
        let cancelErrorCode: RuntimePersistenceNullable<String>

        init(_ row: HostedMigrationRecord) {
            agentId = row.agentId
            serverId = row.serverId
            supportRef = row.supportRef
            revision = row.revision
            state = row.state
            sourceMachineId = .init(row.sourceMachineId)
            canceledAt = .init(row.canceledAt)
            cancelReason = .init(row.cancelReason)
            cancelDispatchAttempts = row.cancelDispatchAttempts
            cancelLastDispatchAt = .init(row.cancelLastDispatchAt)
            cancelErrorCode = .init(row.cancelErrorCode)
        }

        var record: HostedMigrationRecord {
            HostedMigrationRecord(
                agentId: agentId,
                serverId: serverId,
                supportRef: supportRef,
                revision: revision,
                state: state,
                sourceMachineId: sourceMachineId.value,
                canceledAt: canceledAt.value,
                cancelReason: cancelReason.value,
                cancelDispatchAttempts: cancelDispatchAttempts,
                cancelLastDispatchAt: cancelLastDispatchAt.value,
                cancelErrorCode: cancelErrorCode.value
            )
        }
    }
}
