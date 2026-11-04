import Testing
import RaftDaemonClient

private let key = PassiveAxGate.envKey

@Test func offWithoutTheServerFlagWhateverTheEnvSays() {
    #expect(!PassiveAxGate.resolve(serverEnabled: nil, agentEnvVars: nil, processEnv: [:]))
    #expect(!PassiveAxGate.resolve(serverEnabled: false, agentEnvVars: nil, processEnv: [:]))
    #expect(!PassiveAxGate.resolve(serverEnabled: nil, agentEnvVars: [key: "1"], processEnv: [key: "1"]))
}

@Test func onWithTheServerFlagAndNoLocalOpinion() {
    #expect(PassiveAxGate.resolve(serverEnabled: true, agentEnvVars: nil, processEnv: [:]))
    #expect(PassiveAxGate.resolve(serverEnabled: true, agentEnvVars: [:], processEnv: [:]))
}

@Test func theDaemonProcessEnvCanKillIt() {
    for off in ["0", "false", "off", ""] {
        #expect(!PassiveAxGate.resolve(serverEnabled: true, agentEnvVars: nil, processEnv: [key: off]))
    }
    #expect(PassiveAxGate.resolve(serverEnabled: true, agentEnvVars: nil, processEnv: [key: "1"]))
}

@Test func eitherPlaceSayingOffWins() {
    #expect(!PassiveAxGate.resolve(serverEnabled: true, agentEnvVars: [key: "1"], processEnv: [key: "0"]))
    #expect(!PassiveAxGate.resolve(serverEnabled: true, agentEnvVars: [key: "0"], processEnv: [key: "1"]))
    #expect(PassiveAxGate.resolve(serverEnabled: true, agentEnvVars: [key: "1"], processEnv: [key: "1"]))
}

@Test func unparseableValueIsNoOpinion() {
    #expect(PassiveAxGate.resolve(serverEnabled: true, agentEnvVars: [key: "maybe"], processEnv: [:]))
    #expect(PassiveAxGate.resolve(serverEnabled: true, agentEnvVars: nil, processEnv: [key: "yes please"]))
}
