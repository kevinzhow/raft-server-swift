/// The production Feature services and the owner-bound briefing hook assembled
/// from one retained owner graph.
///
/// The values come from the shared explicit-owner composer, not from a second
/// set of stores. A production root keeps this value for its Feature mounts
/// while its durable bindings restore the same owner instances.
public struct ProductionFeatureGraph: Sendable {
    public let services: ServiceContainer
    public let onboardingBriefing: OnboardingBriefingService
}
