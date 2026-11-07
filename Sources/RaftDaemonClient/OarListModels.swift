import Foundation
import Synchronization

/// Reads a runtime's usable-now model list through OAR's `listModels` and
/// projects it onto the closed runtime-model outcome the server understands.
/// The wire stays unchanged: OAR results map only onto existing outcome kinds
/// and error codes. Ported from the upstream daemon model source.
public struct OarModelEntry: Sendable, Equatable {
    public var id: String
    public var displayName: String?
    public var effortLevels: [String]?
    public var defaultEffort: String?
    public var serviceTiers: [String]?
    public var defaultServiceTier: String?
    public var disabled: Bool
    public init(
        id: String, displayName: String? = nil, effortLevels: [String]? = nil,
        defaultEffort: String? = nil, serviceTiers: [String]? = nil,
        defaultServiceTier: String? = nil, disabled: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.effortLevels = effortLevels
        self.defaultEffort = defaultEffort
        self.serviceTiers = serviceTiers
        self.defaultServiceTier = defaultServiceTier
        self.disabled = disabled
    }
}

public enum ListModelsResult: Sendable, Equatable {
    case ok(models: [OarModelEntry])
    case unauthenticated
    case unsupported(reason: String)
}

public protocol OarDeadlineScheduler: Sendable {
    func schedule(afterMs: Int, _ body: @escaping @Sendable () -> Void) -> Int
    func cancel(_ timer: Int)
}

public final class DispatchDeadlineScheduler: OarDeadlineScheduler, Sendable {
    private final class NativeWorkItem: Sendable {
        private let item: Mutex<DispatchWorkItem>
        init(_ body: @escaping @Sendable () -> Void) {
            item = Mutex(DispatchWorkItem(block: body))
        }
        func enqueue(on queue: DispatchQueue, deadline: DispatchTime) {
            item.withLock { queue.asyncAfter(deadline: deadline, execute: $0) }
        }
        func cancel() {
            item.withLock { $0.cancel() }
        }
    }
    private struct State: Sendable {
        var items: [Int: NativeWorkItem] = [:]
        var nextId = 1
    }
    private let state = Mutex(State())
    public init() {}
    public func schedule(afterMs: Int, _ body: @escaping @Sendable () -> Void) -> Int {
        let id = state.withLock { state in
            let id = state.nextId
            state.nextId += 1
            return id
        }
        let item = NativeWorkItem(body)
        state.withLock { $0.items[id] = item }
        let queue = DispatchQueue.global()
        let deadline = DispatchTime.now() + .milliseconds(max(0, afterMs))
        item.enqueue(on: queue, deadline: deadline)
        return id
    }
    public func cancel(_ timer: Int) {
        let item = state.withLock { $0.items.removeValue(forKey: timer) }
        item?.cancel()
    }
}

/// One running listing per lister: a request after our deadline joins the
/// listing still running instead of starting a second one.
public final class ModelLister: Sendable {
    public typealias Run = @Sendable (OarInstallation, Int?) async throws -> ListModelsResult
    let run: Run
    private struct State: Sendable {
        var running: Task<ListModelsResult, Error>? = nil
        var generation = 0
    }
    private let state = Mutex(State())
    public init(_ run: @escaping Run) {
        self.run = run
    }

    func joinOrStart(installation: OarInstallation, timeoutMs: Int) -> Task<ListModelsResult, Error> {
        return state.withLock { state in
            if let running = state.running { return running }
            let run = self.run
            state.generation += 1
            let currentGeneration = state.generation
            let task = Task { try await run(installation, timeoutMs) }
            state.running = task
            Task { [weak self] in
                _ = try? await task.value
                guard let self else { return }
                self.state.withLock { state in
                    if state.generation == currentGeneration { state.running = nil }
                }
            }
            return task
        }
    }
}

public struct ListedModel: Sendable, Equatable {
    public var id: String
    public var label: String
    public var supportedReasoningEfforts: [String]?
    public var defaultReasoningEffort: String?
    public var serviceTiers: [String]?
    public var defaultServiceTier: String?
    public var verified: String?
    public init(
        id: String, label: String, supportedReasoningEfforts: [String]? = nil,
        defaultReasoningEffort: String? = nil, serviceTiers: [String]? = nil,
        defaultServiceTier: String? = nil, verified: String? = nil
    ) {
        self.id = id
        self.label = label
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.serviceTiers = serviceTiers
        self.defaultServiceTier = defaultServiceTier
        self.verified = verified
    }
}

public enum ListModelsOutcome: Sendable, Equatable {
    case live(models: [ListedModel])
    case noModels
    case unsupported
    case error(retryable: Bool, code: String? = nil, reason: String? = nil)
}

public struct OarModelSourceInput: Sendable {
    public var lister: ModelLister
    public var installation: OarInstallation
    public var deadlineMs: Int
    public var listerTimeoutMs: Int?
    public var keepReasoningEfforts: Bool
    public var label: @Sendable (OarModelEntry) -> String
    public var onUnsupported: @Sendable (String) -> ListModelsOutcome
    public var scheduler: OarDeadlineScheduler

    public init(
        lister: ModelLister, installation: OarInstallation, deadlineMs: Int,
        listerTimeoutMs: Int? = nil, keepReasoningEfforts: Bool,
        scheduler: OarDeadlineScheduler = DispatchDeadlineScheduler(),
        label: @escaping @Sendable (OarModelEntry) -> String,
        onUnsupported: @escaping @Sendable (String) -> ListModelsOutcome
    ) {
        self.lister = lister
        self.installation = installation
        self.deadlineMs = deadlineMs
        self.listerTimeoutMs = listerTimeoutMs
        self.keepReasoningEfforts = keepReasoningEfforts
        self.scheduler = scheduler
        self.label = label
        self.onUnsupported = onUnsupported
    }
}

public enum OarListModels {
    final class Once: Sendable {
        private let done = Mutex(false)
        func take() -> Bool {
            done.withLock { done in
                if done { return false }
                done = true
                return true
            }
        }
    }

    enum Raced: Sendable {
        case listing(Result<ListModelsResult, Error>)
        case deadline
    }

    /// First-of race: the deadline is scheduled through the injected scheduler,
    /// so tests can fire it deterministically and no sleeping task is leaked.
    static func race(task: Task<ListModelsResult, Error>, input: OarModelSourceInput) async -> Raced {
        let once = Once()
        return await withCheckedContinuation { continuation in
            let timer = input.scheduler.schedule(afterMs: input.deadlineMs) {
                guard once.take() else { return }
                task.cancel()
                continuation.resume(returning: .deadline)
            }
            Task {
                let result = await task.result
                input.scheduler.cancel(timer)
                if once.take() { continuation.resume(returning: .listing(result)) }
            }
        }
    }

    public static func detect(_ input: OarModelSourceInput) async -> ListModelsOutcome {
        let task = input.lister.joinOrStart(
            installation: input.installation,
            timeoutMs: input.listerTimeoutMs ?? input.deadlineMs + 5_000
        )
        let raced = await race(task: task, input: input)
        switch raced {
        case .deadline:
            return .error(retryable: true, code: "detect_timeout")
        case .listing(.failure):
            return .error(retryable: true)
        case .listing(.success(let result)):
            switch result {
            case .ok(let entries):
                let models = project(entries, input: input)
                return models.isEmpty ? .noModels : .live(models: models)
            case .unauthenticated:
                return .error(retryable: true, code: "runtime_not_authenticated")
            case .unsupported(let reason):
                return input.onUnsupported(reason)
            }
        }
    }

    public static func project(
        _ entries: [OarModelEntry],
        options: (label: @Sendable (OarModelEntry) -> String, keepReasoningEfforts: Bool)
    ) -> [ListedModel] {
        var models: [ListedModel] = []
        var seen = Set<String>()
        for entry in entries {
            // A listed-but-refused model is not launchable; offering it would fail at start.
            if entry.disabled || seen.contains(entry.id) { continue }
            seen.insert(entry.id)
            let efforts = options.keepReasoningEfforts && !(entry.effortLevels?.isEmpty ?? true)
                ? entry.effortLevels : nil
            var effortDefault: String?
            if let efforts, let defaultEffort = entry.defaultEffort, efforts.contains(defaultEffort) {
                effortDefault = defaultEffort
            }
            models.append(ListedModel(
                id: entry.id, label: options.label(entry),
                supportedReasoningEfforts: efforts, defaultReasoningEffort: effortDefault,
                serviceTiers: entry.serviceTiers?.isEmpty == false ? entry.serviceTiers : nil,
                defaultServiceTier: entry.defaultServiceTier,
                verified: "launchable"
            ))
        }
        return models
    }

    public static func project(
        _ entries: [OarModelEntry],
        input: OarModelSourceInput
    ) -> [ListedModel] {
        project(entries, options: (label: input.label, keepReasoningEfforts: input.keepReasoningEfforts))
    }
}
