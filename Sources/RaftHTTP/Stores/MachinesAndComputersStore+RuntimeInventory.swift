import Foundation

extension MachinesAndComputersStore {
    var machineQueries: (any MachineQuerying)? {
        get { storage.withLock { $0.machineQueries } }
        set { storage.withLock { $0.machineQueries = newValue } }
    }

    /// Shared display catalog normalization follows runtimeModelCatalog.ts.
    /// Invalid/empty reports retain the previous copy; this cache never grants
    /// runtime availability or supplies a successful production probe.
    func recordRuntimeModelCatalog(machineId: String, runtime: String,
                                   models: [MachineRuntimeModelSource.Model], observedAt: Date) {
        guard !runtime.isEmpty, !models.isEmpty, models.count <= 500 else { return }
        var order: [String] = []
        var labels: [String: String] = [:]
        func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.value <= 31 || (127...159).contains(scalar.value) }
        for model in models {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = String(String.UnicodeScalarView(model.label.unicodeScalars.filter { !isControl($0) }))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !id.unicodeScalars.contains(where: isControl), id.utf16.count <= 200,
                  !label.isEmpty, label.utf16.count <= 200 else { continue }
            if labels[id] == nil { order.append(id) }
            labels[id] = label
        }
        guard !order.isEmpty else { return }
        storage.withLock { state in
            state.machineRuntimeModels[machineId, default: [:]][runtime] = (
                order.compactMap { id in labels[id].map { (id: id, label: $0) } }, observedAt
            )
        }
    }

    /// Invoked only after the same UoW validates execution connection ownership
    /// and epoch. Node pending preserves inventory; incomplete retains only the
    /// previous runtimes explicitly unfinished in this detection round.
    func recordReadyInventory(machineId: String, serverId: String,
                              report: MachineRuntimeInventoryReport, observedAt: Date) {
        storage.withLock { state in
            guard let index = state.machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else { return }
            var machine = state.machines[index]
            let detection = report.runtimeDetection
            if detection?.status != .pending {
                var runtimes = report.runtimes ?? []
                let allowed = Set(runtimes)
                var versions = (report.runtimeVersions ?? [:]).filter { runtime, version in
                    allowed.contains(runtime) && runtime.utf16.count <= 64
                        && !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && version.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count <= 128
                }.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if detection?.status == .incomplete {
                    let unfinished = Set(detection?.unfinishedRuntimes ?? [])
                    var seen = Set<String>()
                    runtimes = runtimes.filter { seen.insert($0).inserted }
                    for old in machine.runtimes where unfinished.contains(old) {
                        if seen.insert(old).inserted { runtimes.append(old) }
                        if versions[old] == nil, let version = machine.runtimeVersions[old], !version.isEmpty { versions[old] = version }
                    }
                }
                machine.runtimes = runtimes
                machine.runtimeVersions = versions
            }
            if let detection {
                let unfinished = detection.status == .incomplete
                    ? (detection.unfinishedRuntimes ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } : nil
                let reason = detection.status == .incomplete
                    ? (["deadline", "child_failed", "cancelled"].contains(detection.reason ?? "") ? detection.reason : "child_failed") : nil
                machine.runtimeDetection = .init(status: detection.status, reason: reason, unfinishedRuntimes: unfinished,
                    durationMs: detection.durationMs, updatedAtMs: Int(observedAt.timeIntervalSince1970 * 1000))
                state.machineRuntimeDetections[machineId] = (detection.status.rawValue, Set(unfinished ?? []))
            } else {
                machine.runtimeDetection = nil
                state.machineRuntimeDetections.removeValue(forKey: machineId)
            }
            state.machines[index] = machine
        }
    }
}
