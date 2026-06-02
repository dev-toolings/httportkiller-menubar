import Foundation

public struct PortKiller: Sendable {
    private let lsofProvider: any LsofProviding
    private let processInspector: any ProcessInspecting
    private let termGrace: TimeInterval
    private let killGrace: TimeInterval

    public init(
        lsofProvider: any LsofProviding = SystemLsofProvider(),
        processInspector: any ProcessInspecting = SystemProcessInspector(),
        termGrace: TimeInterval = 0.6,
        killGrace: TimeInterval = 0.6
    ) {
        self.lsofProvider = lsofProvider
        self.processInspector = processInspector
        self.termGrace = termGrace
        self.killGrace = killGrace
    }

    public func kill(_ port: PortInfo) -> KillResult {
        let pid = port.pid

        guard processInspector.isProcessAlive(pid: pid) else {
            return .alreadyExited
        }

        guard pidOwnsListeningPort(pid: pid, port: UInt16(port.port)) else {
            return .alreadyExited
        }

        let termResult = Darwin.kill(pid, SIGTERM)
        if termResult != 0 {
            return killErrorResult(errno)
        }

        if waitForExit(pid: pid, timeout: termGrace) {
            return .success
        }

        let killResult = Darwin.kill(pid, SIGKILL)
        if killResult != 0 {
            return killErrorResult(errno)
        }

        if waitForExit(pid: pid, timeout: killGrace) {
            return .success
        }

        return .timedOut
    }

    private func pidOwnsListeningPort(pid: Int32, port: UInt16) -> Bool {
        guard let output = try? lsofProvider.listenerOutput(pid: pid) else {
            return false
        }

        return LsofParser.parseTable(output).contains {
            $0.pid == pid && $0.port == Int(port)
        }
    }

    private func waitForExit(pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !processInspector.isProcessAlive(pid: pid) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        return !processInspector.isProcessAlive(pid: pid)
    }

    private func killErrorResult(_ error: Int32) -> KillResult {
        switch error {
        case ESRCH:
            return .alreadyExited
        case EPERM:
            return .permissionDenied
        default:
            return .failed(String(cString: strerror(error)))
        }
    }
}
