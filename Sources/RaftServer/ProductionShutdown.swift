import RaftHTTP
import RaftMachineSocket
import RaftRealtime
import Vapor

struct ProductionShutdown: LifecycleHandler {
    let runtime: BusinessPersistenceRuntime
    let worker: ProductionEmailWorker?
    let publicationWorker: ProductionRealtimePublicationWorker?
    let executionConnection: ProductionAgentExecutionConnection?
    let machineServer: MachineConnectServer?
    let realtimeServer: RealtimeServer?

    func shutdown(_ application: Application) async {
        await worker?.stop()
        await publicationWorker?.stop()
        await executionConnection?.worker.stop()
        // Stop accepts and finish admitted offline commits before revoking the
        // writer. close then stops admission, drains its FIFO and closes leases.
        try? await machineServer?.close()
        await executionConnection?.registry.close()
        await runtime.close()
        try? await realtimeServer?.close()
    }
}
