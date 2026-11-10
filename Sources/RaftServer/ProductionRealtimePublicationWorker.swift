import Foundation
import Synchronization
import RaftHTTP
import RaftPersistence
import RaftRealtime
import RaftShared

/// One serial consumer on the production graph's existing fenced runtime.
/// Delivery means handing the publication to the real hub, not a subscriber ACK.
/// A crash or unknown SQL acknowledgement can produce another frame later.
struct ProductionRealtimePublicationWorker: Sendable {
    private let task: Task<Void, Never>

    init(runtime: BusinessPersistenceRuntime, hub: RealtimeHub) throws {
        let kind = try DurableEffectKind("realtime.publish")
        task = Task.detached {
            while !Task.isCancelled {
                do {
                    let claims = try await runtime.claimOutbox(kinds: [kind], limit: 1, visibilityTimeoutSeconds: 90)
                    guard let claim = claims.first else {
                        try await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    try Task.checkCancellation()
                    guard runtime.readinessSnapshot.isReady, claim.expiresAt > Date() else {
                        throw PersistenceError.outboxClaimLost
                    }
                    do {
                        // Hub handoff is a deferred effect. The same runtime
                        // must confirm its writer-fenced commit before flushing
                        // that effect under the production delivery scope.
                        let handoff = try await runtime.execute {
                            guard claim.expiresAt > Date() else {
                                throw PersistenceError.outboxClaimLost
                            }
                            return try ProductionRealtimePublicationDelivery.enqueue(
                                claim.entry.effect, hub: hub, expiresAt: claim.expiresAt,
                                isReady: { runtime.readinessSnapshot.isReady }
                            )
                        }
                        try handoff.requireHandoffForAcknowledgement()
                    } catch ProductionRealtimePublicationDelivery.Failure.rejected {
                        // Only a corrupt publication is a rejected delivery.
                        // SQL failures escape to the outer lifecycle boundary.
                        try await runtime.recordFailure(claim, code: .rejected)
                        continue
                    }
                    // No cancellation check or send-failure handler belongs
                    // between the hub handoff and this single acknowledgement.
                    // A failed mark must never cause an immediate blind re-emit.
                    try await runtime.markDelivered(claim)
                } catch {
                    if Task.isCancelled || !runtime.readinessSnapshot.isReady { return }
                    // Database errors and payloads can contain private data.
                    // Keep the persisted claim and its bounded retry history.
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Stop before the shared hub or persistence runtime is closed.
    func stop() async {
        task.cancel()
        await task.value
    }
}

/// The same checked publication-to-hub boundary used by the production consumer
/// and actual socket acceptance. There is no alternate emitter or receiver spy.
enum ProductionRealtimePublicationDelivery {
    enum Failure: Error, Sendable, Equatable { case rejected }

    enum HandoffOutcome: Sendable, Equatable {
        case queued, expired, notReady, handedOff
    }

    /// Ephemeral completion of the real deferred handoff, never a durable ACK.
    final class Handoff: Sendable {
        private let state = Mutex<HandoffOutcome>(.queued)

        var outcome: HandoffOutcome { state.withLock { $0 } }

        /// The worker must pass this gate before its separately fenced SQL ACK.
        func requireHandoffForAcknowledgement() throws {
            guard outcome == .handedOff else { throw PersistenceError.outboxClaimLost }
        }

        fileprivate func complete(_ outcome: HandoffOutcome) {
            state.withLock { current in
                precondition(current == .queued && outcome != .queued)
                current = outcome
            }
        }
    }

    /// Validate before queueing; admission is checked again when the confirmed
    /// runtime actually flushes this closure. The clock is an input for bounded
    /// expiry tests; production uses the current wall time.
    static func enqueue(
        _ effect: DurableEffect, hub: RealtimeHub, expiresAt: Date,
        isReady: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Handoff {
        let publication = try validate(effect)
        let handoff = Handoff()
        DeferredEffects.emit {
            guard expiresAt > now() else {
                handoff.complete(.expired)
                return
            }
            guard isReady() else {
                handoff.complete(.notReady)
                return
            }
            // Inside the existing effect-flush scope hub.emit performs its real
            // synchronous handoff immediately, without creating another intent.
            hub.emit(room: publication.room, event: publication.event, payloadJSON: publication.payloadJSON)
            handoff.complete(.handedOff)
        }
        return handoff
    }

    static func validate(_ effect: DurableEffect) throws -> RealtimePublication {
        guard effect.kind.rawValue == "realtime.publish",
              effect.payload.count <= PersistenceLimits.maximumEffectPayloadBytes,
              let publication = try? JSONDecoder().decode(RealtimePublication.self, from: effect.payload),
              publication.codec == "raft-realtime-publication-v1",
              publication.eventId == effect.effectID,
              validName(publication.room, maximumBytes: 1_024),
              validName(publication.event, maximumBytes: 128) else { throw Failure.rejected }
        let payload = Data(publication.payloadJSON.utf8)
        guard payload.count <= PersistenceLimits.maximumEffectPayloadBytes,
              (try? JSONDecoder().decode(JSONValue.self, from: payload)) != nil else { throw Failure.rejected }
        return publication
    }

    static func publish(_ effect: DurableEffect, hub: RealtimeHub) throws {
        let publication = try validate(effect)
        // JSONValue is a validator only. Preserve every original payload byte,
        // including number spelling, escapes and member order, for the real hub.
        hub.emit(room: publication.room, event: publication.event, payloadJSON: publication.payloadJSON)
    }

    private static func validName(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
