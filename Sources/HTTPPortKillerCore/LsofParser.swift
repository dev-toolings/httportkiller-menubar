import Foundation

public enum LsofParser {
    public static func parseTable(_ output: String, commands: [Int32: String] = [:]) -> [PortInfo] {
        var results: [PortInfo] = []
        var seen = Set<String>()

        for line in output.split(separator: "\n").dropFirst() {
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            guard components.count >= 9 else {
                continue
            }

            let processName = decodeLsofEscapes(String(components[0]))
            guard let pid = Int32(components[1]) else {
                continue
            }

            let user = String(components[2])
            let fd = String(components[3])
            guard let address = addressComponent(from: components),
                  let port = parsePort(fromNameField: String(address)) else {
                continue
            }

            let key = "\(pid):\(port)"
            guard seen.insert(key).inserted else {
                continue
            }

            results.append(PortInfo(
                port: Int(port),
                pid: pid,
                processName: processName,
                address: String(address),
                user: user,
                command: commands[pid] ?? processName,
                fd: fd
            ))
        }

        return results.sorted {
            if $0.port == $1.port {
                return $0.pid < $1.pid
            }
            return $0.port < $1.port
        }
    }

    public static func parsePort(fromNameField name: String) -> UInt16? {
        if name.contains("->") {
            return nil
        }

        let cleaned = name.replacingOccurrences(of: " (LISTEN)", with: "")
        guard let colonIndex = cleaned.lastIndex(of: ":") else {
            return nil
        }

        let suffix = cleaned[cleaned.index(after: colonIndex)...]
        let digits = suffix.prefix { $0.isNumber }
        guard !digits.isEmpty else {
            return nil
        }

        return UInt16(digits)
    }

    private static func addressComponent(from components: [Substring]) -> Substring? {
        for index in stride(from: components.count - 1, through: 8, by: -1) {
            let component = components[index]
            if component.contains(":") && !component.hasPrefix("0x") && !component.hasPrefix("0t") {
                return component
            }
        }
        return nil
    }

    private static func decodeLsofEscapes(_ input: String) -> String {
        var result = ""
        var index = input.startIndex

        while index < input.endIndex {
            if input[index] == "\\",
               input.distance(from: index, to: input.endIndex) >= 4,
               input[input.index(after: index)] == "x" {
                let hexStart = input.index(index, offsetBy: 2)
                let hexEnd = input.index(index, offsetBy: 4)
                let hex = String(input[hexStart..<hexEnd])
                if let byte = UInt8(hex, radix: 16) {
                    result.append(Character(UnicodeScalar(byte)))
                    index = hexEnd
                    continue
                }
            }
            result.append(input[index])
            index = input.index(after: index)
        }

        return result
    }
}
