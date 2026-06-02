import Foundation
import Testing
@testable import HTTPPortKillerCore

@Test
func detectsAndKillsTemporaryHTTPServer() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
        return
    }

    // Inline server instead of `-m http.server` so the child dies with us even
    // on a hard kill: it blocks on `sys.stdin.read()`, and the parent holds the
    // write end of the stdin pipe. If this test process is SIGKILLed before the
    // `defer` runs, the kernel closes the pipe -> EOF -> the server self-exits,
    // so no orphaned listener leaks to launchd. It stays a single direct child,
    // so the PID still owns the socket for lsof discovery and the kill below.
    let server = """
    import http.server, socketserver, sys, threading
    srv = socketserver.TCPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    sys.stdin.read()
    """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", server]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    // Held open by this process; closing on our death is what triggers the
    // self-exit watchdog above.
    process.standardInput = Pipe()

    try process.run()
    defer {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    guard let port = waitForPythonServerPort(pid: process.processIdentifier) else {
        Issue.record("temporary HTTP server did not expose a listening port")
        return
    }

    let candidate = PortInfo(
        port: Int(port),
        pid: process.processIdentifier,
        processName: "Python",
        address: "127.0.0.1:\(port)",
        user: NSUserName(),
        command: "/usr/bin/python3 -m http.server",
        fd: "4u"
    )

    let killer = PortKiller(termGrace: 1.0, killGrace: 1.0)
    let result = killer.kill(candidate)

    #expect(result == .success || result == .alreadyExited)
    #expect(waitForPortToClose(pid: process.processIdentifier, port: port))
}

private func waitForPythonServerPort(pid: Int32) -> UInt16? {
    let deadline = Date().addingTimeInterval(4.0)
    while Date() < deadline {
        let provider = SystemLsofProvider()
        if
            let output = try? provider.listenerOutput(pid: pid),
            let port = LsofParser.parseTable(output).first?.port
        {
            return UInt16(port)
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
}

private func waitForPortToClose(pid: Int32, port: UInt16) -> Bool {
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
        let provider = SystemLsofProvider()
        let stillListening = (try? provider.listenerOutput(pid: pid))
            .map { LsofParser.parseTable($0).contains { $0.port == Int(port) } } ?? false
        if !stillListening {
            return true
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return false
}
