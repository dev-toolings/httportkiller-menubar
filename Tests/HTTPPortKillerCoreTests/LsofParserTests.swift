import Testing
@testable import HTTPPortKillerCore

@Test
func parsesTableOutputAndDeduplicatesPidPortPairs() {
    let output = """
    COMMAND     PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    node        123  kevin  21u  IPv6 0xabc       0t0    TCP *:3000 (LISTEN)
    node        123  kevin  22u  IPv4 0xdef       0t0    TCP 127.0.0.1:3000 (LISTEN)
    Python      456  kevin   4u  IPv4 0xghi       0t0    TCP 127.0.0.1:5173 (LISTEN)
    """

    let ports = LsofParser.parseTable(output, commands: [123: "node server.js", 456: "python3 -m http.server"])

    #expect(ports.count == 2)
    #expect(ports[0].port == 3000)
    #expect(ports[0].pid == 123)
    #expect(ports[0].processName == "node")
    #expect(ports[0].command == "node server.js")
    #expect(ports[1].port == 5173)
}

@Test
func parsesSupportedEndpointFormats() {
    #expect(LsofParser.parsePort(fromNameField: "*:3000") == 3000)
    #expect(LsofParser.parsePort(fromNameField: "127.0.0.1:5173") == 5173)
    #expect(LsofParser.parsePort(fromNameField: "[::1]:8000") == 8000)
    #expect(LsofParser.parsePort(fromNameField: "127.0.0.1:3000 (LISTEN)") == 3000)
}

@Test
func rejectsInvalidEndpointFormats() {
    #expect(LsofParser.parsePort(fromNameField: "127.0.0.1:abcd") == nil)
    #expect(LsofParser.parsePort(fromNameField: "127.0.0.1->192.168.0.1:1234") == nil)
    #expect(LsofParser.parsePort(fromNameField: "garbage") == nil)
}
