import Foundation

extension ProductEventStore {
    /// Both event arrays are business ledgers, despite RecordedProductEvent's
    /// historical name. Preserve their order and every valid batch id, including
    /// ids whose client row was filtered out. Never derive seenIDs from rows.
    /// State has no callbacks, diagnostic counters or runtime configuration.
    func exportPersistenceData() throws -> Data {
        let captured = state.withLock { $0 }
        return try ProductFeedbackPersistenceFormat.encode(
            PFProductEventsSnapshot(captured), owner: "raft.product-events"
        )
    }

    /// All required keys are decoded before replacement. Conversion also occurs
    /// outside the lock; restoring does not append, deduplicate or replay events.
    func restorePersistenceData(_ data: Data) throws {
        let decoded = try ProductFeedbackPersistenceFormat.decode(
            PFProductEventsSnapshot.self, from: data, owner: "raft.product-events"
        )
        let productEvents = decoded.productEvents.map { $0.restored() }
        let clientEvents = decoded.clientEvents.map { $0.restored() }
        let seenIDs = Set(decoded.seenClientEventIDs)
        state.withLock { current in
            current.productEvents = productEvents
            current.clientEvents = clientEvents
            current.seenClientEventIDs = seenIDs
        }
    }
}

private struct PFProductEventsSnapshot: Codable, Sendable {
    let productEvents: [PFProductEvent]
    let clientEvents: [PFClientEvent]
    let seenClientEventIDs: [String]

    init(_ state: ProductEventStore.State) {
        productEvents = state.productEvents.map(PFProductEvent.init)
        clientEvents = state.clientEvents.map(PFClientEvent.init)
        seenClientEventIDs = state.seenClientEventIDs.sorted()
    }
}

private struct PFProductEvent: Codable, Sendable {
    let subjectType: String
    let subjectId: String
    let eventType: String
    let actorType: String
    let actorId: String
    let source: String
    let idempotencyKey: ProductFeedbackPersistenceNullable<String>
    let metadataJSON: String

    init(_ record: RecordedProductEvent) {
        subjectType = record.subjectType
        subjectId = record.subjectId
        eventType = record.eventType
        actorType = record.actorType
        actorId = record.actorId
        source = record.source
        idempotencyKey = ProductFeedbackPersistenceNullable(record.idempotencyKey)
        metadataJSON = record.metadataJSON
    }

    func restored() -> RecordedProductEvent {
        RecordedProductEvent(
            subjectType: subjectType,
            subjectId: subjectId,
            eventType: eventType,
            actorType: actorType,
            actorId: actorId,
            source: source,
            idempotencyKey: idempotencyKey.value,
            metadataJSON: metadataJSON
        )
    }
}

private struct PFClientEvent: Codable, Sendable {
    let event: String
    let analyticsId: String
    let serverId: String
    let source: String
    let sessionId: String
    let appVersion: ProductFeedbackPersistenceNullable<String>
    let propertiesJSON: String

    init(_ record: ClientEventRecord) {
        event = record.event
        analyticsId = record.analyticsId
        serverId = record.serverId
        source = record.source
        sessionId = record.sessionId
        appVersion = ProductFeedbackPersistenceNullable(record.appVersion)
        propertiesJSON = record.propertiesJSON
    }

    func restored() -> ClientEventRecord {
        ClientEventRecord(
            event: event,
            analyticsId: analyticsId,
            serverId: serverId,
            source: source,
            sessionId: sessionId,
            appVersion: appVersion.value,
            propertiesJSON: propertiesJSON
        )
    }
}
