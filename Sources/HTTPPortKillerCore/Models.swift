import Foundation

public enum ProcessType: String, Sendable, CaseIterable {
    case webServer
    case database
    case development
    case system
    case container
    case other

    public static func detect(from processName: String, command: String = "") -> ProcessType {
        let text = "\(processName) \(command)".lowercased()

        if text.contains("orbstack") || text.contains("docker") || text.contains("container") {
            return .container
        }

        if [
            "postgres", "mysql", "mariadb", "redis", "mongod", "memcached", "rabbitmq",
            "elasticsearch", "meilisearch",
        ].contains(where: text.contains) {
            return .database
        }

        if [
            "node", "vite", "next", "nuxt", "astro", "bun", "deno", "python", "uvicorn",
            "gunicorn", "rails", "ruby", "php", "nginx", "caddy", "httpd",
        ].contains(where: text.contains) {
            return .webServer
        }

        if [
            "code helper", "java", "gradle", "mvn", "go", "cargo", "xcodebuild",
        ].contains(where: text.contains) {
            return .development
        }

        if [
            "controlcenter", "controlce", "rapportd", "sharingd", "configd",
            "mdnsresponder", "apsd",
        ].contains(where: text.contains) {
            return .system
        }

        return .other
    }

    public var iconName: String {
        switch self {
        case .webServer:
            return "globe"
        case .database:
            return "cylinder.split.1x2"
        case .development:
            return "hammer"
        case .system:
            return "gearshape"
        case .container:
            return "shippingbox"
        case .other:
            return "network"
        }
    }

    public var title: String {
        switch self {
        case .webServer:
            return "Web Server"
        case .database:
            return "Database"
        case .development:
            return "Development"
        case .container:
            return "Container"
        case .system:
            return "System"
        case .other:
            return "Other"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .webServer:
            return 0
        case .database:
            return 1
        case .development:
            return 2
        case .container:
            return 3
        case .system:
            return 4
        case .other:
            return 5
        }
    }
}

public struct PortInfo: Identifiable, Hashable, Sendable {
    public let port: Int
    public let pid: Int32
    public let processName: String
    public let address: String
    public let user: String
    public let command: String
    public let fd: String
    public let isActive: Bool
    public let processType: ProcessType

    public init(
        port: Int,
        pid: Int32,
        processName: String,
        address: String,
        user: String,
        command: String,
        fd: String,
        isActive: Bool = true,
        processType: ProcessType? = nil
    ) {
        self.port = port
        self.pid = pid
        self.processName = processName
        self.address = address
        self.user = user
        self.command = command
        self.fd = fd
        self.isActive = isActive
        self.processType = processType ?? ProcessType.detect(from: processName, command: command)
    }

    public var id: String {
        "\(port):\(pid):\(fd):\(isActive)"
    }

    public var displayPort: String {
        ":\(port)"
    }
}

public struct ProcessGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let processName: String
    public let pids: [Int32]
    public let ports: [PortInfo]

    public init(processName: String, ports: [PortInfo]) {
        self.id = processName
        self.processName = processName
        self.ports = ports.sorted { $0.port < $1.port }
        self.pids = Array(Set(ports.map(\.pid))).sorted()
    }
}

public enum KillResult: Equatable, Sendable {
    case success
    case alreadyExited
    case permissionDenied
    case timedOut
    case failed(String)
}
