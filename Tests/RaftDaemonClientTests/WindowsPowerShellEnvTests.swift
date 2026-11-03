import Foundation
import RaftDaemonClient
import Testing

@Test func windowsPowerShellChildEnvRemovesEveryModulePathCaseVariantWithoutMutatingSource() {
    let source = [
        "Path": "C:\\Windows\\System32",
        "PSModulePath": "C:\\Program Files\\PowerShell\\Modules",
        "psmodulepath": "C:\\Users\\test\\Documents\\PowerShell\\Modules",
        "TASK_ENV": "present",
    ]
    let childEnv = WindowsPowerShellEnv.childEnv(from: source)
    #expect(childEnv == ["Path": "C:\\Windows\\System32", "TASK_ENV": "present"])
    #expect(source.count == 4, "the source environment is not mutated")
    #expect(source["PSModulePath"] != nil)
}

@Test func windowsPowerShellChildEnvSanitizesTheInheritedEnvironment() {
    let previous = ProcessInfo.processInfo.environment["PSModulePath"]
    setenv("PSModulePath", "C:\\Program Files\\PowerShell\\7\\Modules", 1)
    defer {
        if let previous { setenv("PSModulePath", previous, 1) } else { unsetenv("PSModulePath") }
    }
    let childEnv = WindowsPowerShellEnv.childEnv()
    #expect(!childEnv.keys.contains { $0.lowercased() == "psmodulepath" })
}
