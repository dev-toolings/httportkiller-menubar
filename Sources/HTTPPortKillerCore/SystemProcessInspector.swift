import Foundation

public protocol LsofProviding: Sendable {
    func listeningTCPOutput() throws -> String
    func listenerOutput(pid: Int32) throws -> String
}

public protocol ProcessInspecting: Sendable {
    func commandLine(pid: Int32) -> String?
    func isProcessAlive(pid: Int32) -> Bool
}

public struct SystemLsofProvider: LsofProviding {
    public init() {}

    public func listeningTCPOutput() throws -> String {
        try run("/usr/sbin/lsof", arguments: ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "+c", "0"])
    }

    public func listenerOutput(pid: Int32) throws -> String {
        try run("/usr/sbin/lsof", arguments: [
            "-iTCP",
            "-sTCP:LISTEN",
            "-P",
            "-n",
            "+c",
            "0",
            "-a",
            "-p",
            String(pid),
        ])
    }

    private func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "lsof failed"
            throw RuntimeCommandError(message)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}

public struct SystemProcessInspector: ProcessInspecting {
    public init() {}

    public func commandLine(pid: Int32) -> String? {
        runPS(pid: pid, format: "command=")
    }

    public func isProcessAlive(pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }

    private func runPS(pid: Int32, format: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", format]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

public struct RuntimeCommandError: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
