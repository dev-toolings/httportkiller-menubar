import Testing
@testable import HTTPPortKillerCore

private struct StubLsofProvider: LsofProviding {
    let output: String

    func listeningTCPOutput() throws -> String {
        output
    }

    func listenerOutput(pid: Int32) throws -> String {
        output
    }
}

private struct StubProcessInspector: ProcessInspecting {
    let commands: [Int32: String]

    func commandLine(pid: Int32) -> String? {
        commands[pid]
    }

    func isProcessAlive(pid: Int32) -> Bool {
        true
    }
}

@Test
func scanReturnsAllListeningTCPPortsWithoutHTTPFiltering() throws {
    let scanner = PortScanner(
        lsofProvider: StubLsofProvider(output: """
        COMMAND     PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node        1    kevin  21u  IPv6 0xabc       0t0    TCP *:3000 (LISTEN)
        redis-ser   2    kevin  12u  IPv4 0xdef       0t0    TCP *:6379 (LISTEN)
        ControlCe   3    kevin   8u  IPv4 0xghi       0t0    TCP *:5000 (LISTEN)
        """),
        processInspector: StubProcessInspector(commands: [
            1: "node server.js",
            2: "redis-server *:6379",
            3: "ControlCenter",
        ])
    )

    let ports = try scanner.scan()

    #expect(ports.map(\.port) == [3000, 5000, 6379])
    #expect(ports.contains { $0.processType == .system })
    #expect(ports.contains { $0.processType == .database })
}
