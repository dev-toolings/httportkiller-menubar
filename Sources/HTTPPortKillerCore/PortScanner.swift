import Foundation

public struct PortScanner: Sendable {
    private let lsofProvider: any LsofProviding
    private let processInspector: any ProcessInspecting

    public init(
        lsofProvider: any LsofProviding = SystemLsofProvider(),
        processInspector: any ProcessInspecting = SystemProcessInspector()
    ) {
        self.lsofProvider = lsofProvider
        self.processInspector = processInspector
    }

    public func scan() throws -> [PortInfo] {
        let raw = try lsofProvider.listeningTCPOutput()
        let pids = extractPIDs(from: raw)
        let commands = Dictionary(uniqueKeysWithValues: pids.map { pid in
            (pid, processInspector.commandLine(pid: pid) ?? "")
        })
        return LsofParser.parseTable(raw, commands: commands)
    }

    private func extractPIDs(from output: String) -> Set<Int32> {
        var pids = Set<Int32>()
        for line in output.split(separator: "\n").dropFirst() {
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            guard components.count >= 2, let pid = Int32(components[1]) else {
                continue
            }
            pids.insert(pid)
        }
        return pids
    }
}
