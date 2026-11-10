import Foundation
import RaftPersistence

extension FencedWriterCheck {
    /// Consumers may claim their own kinds without advancing another consumer's
    /// attempts. These checks use the same real fenced PostgreSQL writer.
    static func exerciseKindFilteredOutbox(
        persistence: PostgresPersistence, epoch: Int64, namespace: Namespace
    ) async throws {
        let emailKind = try DurableEffectKind("auth.verify-email.v1")
        let executionKind = try DurableEffectKind("agent.execution")
        let publicationKind = try DurableEffectKind("realtime.publish")
        let email = try DurableEffect(kind: emailKind, payload: Data([1]))
        let execution = try DurableEffect(kind: executionKind, payload: Data([2]))
        let publication = try DurableEffect(kind: publicationKind, payload: Data([3]))
        let key = try namespace.key(.messagesAndThreads, "consumer-kind-isolation")
        _ = try await persistence.compareAndSwap([
            .put(Fact(value: 1, witness: "three-isolated-consumers"), key: key, codecVersion: 1, expectedRevision: nil),
        ], expectedWriterEpoch: epoch, effects: [email, execution, publication])
        let emailClaims = try await persistence.claimOutbox(expectedWriterEpoch: epoch, kinds: [emailKind])
        try require(emailClaims.count == 1 && emailClaims[0].entry.effect.effectID == email.effectID)
        try require(try await effect(persistence, execution).attempts == 0)
        try require(try await effect(persistence, publication).attempts == 0)
        try await persistence.deferOutbox(emailClaims[0], expectedWriterEpoch: epoch, retryAfterSeconds: 1)
        try require(try await effect(persistence, email).attempts == 0)
        do {
            try await persistence.deferOutbox(emailClaims[0], expectedWriterEpoch: epoch, retryAfterSeconds: 1)
            throw Reason.assertion
        } catch PersistenceError.outboxClaimLost {}
        try await Task.sleep(for: .milliseconds(1200))
        let readyEmail = try await persistence.claimOutbox(expectedWriterEpoch: epoch, kinds: [emailKind])
        try require(readyEmail.count == 1 && readyEmail[0].claimToken != emailClaims[0].claimToken)
        try await persistence.markDelivered(readyEmail[0], expectedWriterEpoch: epoch)
        let executionClaims = try await persistence.claimOutbox(expectedWriterEpoch: epoch, kinds: [executionKind])
        try require(executionClaims.count == 1 && executionClaims[0].entry.effect.effectID == execution.effectID)
        try require(try await effect(persistence, publication).attempts == 0)
        try await persistence.markDelivered(executionClaims[0], expectedWriterEpoch: epoch)
        let publications = try await persistence.claimOutbox(expectedWriterEpoch: epoch, kinds: [publicationKind])
        try require(publications.count == 1 && publications[0].entry.effect.effectID == publication.effectID)
        try await persistence.markDelivered(publications[0], expectedWriterEpoch: epoch)
        do {
            _ = try await persistence.claimOutbox(expectedWriterEpoch: epoch, kinds: [])
            throw Reason.assertion
        } catch PersistenceError.invalidOutboxRequest {}
        for item in [email, execution, publication] {
            let stored = try await effect(persistence, item)
            try require(stored.attempts == 1 && stored.deliveredAt != nil && stored.exhaustedAt == nil)
        }
    }
}
