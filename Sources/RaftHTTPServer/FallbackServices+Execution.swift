import RaftHTTP

public extension FallbackServices {
    /// The supplied business writer and the retained account graph are the only
    /// execution assembly inputs. Missing persistence leaves execution unbound;
    /// no in-memory writer or successful placeholder is manufactured here.
    var agentExecution: AgentExecutionService? {
        guard let persistence else { return nil }
        return emailAccounts.agentExecution(persistence: persistence)
    }

    var humanMessageCreate: HumanMessageCreateService {
        emailAccounts.humanMessageCreate.bindingExecution(agentExecution)
    }

    var taskCatalog: TaskCatalogService {
        emailAccounts.taskCatalog.bindingExecution(agentExecution)
    }

    var tasksAndLabs: TasksAndLabsService {
        emailAccounts.tasksAndLabs.bindingExecution(agentExecution)
    }

    var agentSurface: AgentPrivateSurfaceService {
        emailAccounts.agentSurface.bindingExecution(agentExecution)
    }

    var agentMachineMigrationControl: AgentMachineMigrationControlService {
        emailAccounts.agentMachineMigrationControl.bindingExecution(agentExecution)
    }
}
