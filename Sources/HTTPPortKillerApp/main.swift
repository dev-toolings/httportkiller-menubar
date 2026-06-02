import AppKit
import Foundation
import HTTPPortKillerCore
import SwiftUI
import UserNotifications

enum PortSectionKind: Hashable {
    case favorites
    case watched
    case category(ProcessType)
}

struct PortSection: Identifiable {
    let kind: PortSectionKind
    let ports: [PortInfo]

    var id: String {
        switch kind {
        case .favorites:
            return "favorites"
        case .watched:
            return "watched"
        case .category(let type):
            return "cat-\(type.rawValue)"
        }
    }

    var title: String {
        switch kind {
        case .favorites:
            return "Favorites"
        case .watched:
            return "Watched"
        case .category(let type):
            return type.title
        }
    }

    var icon: String {
        switch kind {
        case .favorites:
            return "star.fill"
        case .watched:
            return "eye.fill"
        case .category(let type):
            return type.iconName
        }
    }
}

enum NotificationManager {
    // UNUserNotificationCenter requires a bundle; calling it from an unbundled
    // `swift run` process crashes. Guard on the bundle identifier so dev runs
    // degrade gracefully while the packaged .app delivers notifications.
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard isAvailable else {
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard isAvailable else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

extension ProcessType {
    var tint: Color {
        switch self {
        case .webServer:
            return .green
        case .database:
            return .purple
        case .development:
            return .orange
        case .container:
            return .cyan
        case .system:
            return .gray
        case .other:
            return .gray
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var ports: [PortInfo] = []
    @Published var searchText = ""
    @Published var isRefreshing = false
    @Published var feedback: String?
    @Published var pendingKillIDs = Set<String>()

    @Published var useTreeView: Bool {
        didSet { defaults.set(useTreeView, forKey: Keys.useTreeView) }
    }

    @Published var favoritePorts: Set<Int> {
        didSet { defaults.set(Array(favoritePorts), forKey: Keys.favoritePorts) }
    }

    @Published var watchedPorts: Set<Int> {
        didSet {
            defaults.set(Array(watchedPorts), forKey: Keys.watchedPorts)
            lastWatchedOpen = currentWatchedOpen(in: ports)
        }
    }

    private let scanner = PortScanner()
    private let killer = PortKiller()
    private let defaults = UserDefaults.standard
    private var autoRefreshTask: Task<Void, Never>?
    private var hasPendingRefreshRequest = false
    private var didStart = false
    private var lastWatchedOpen = Set<Int>()

    private enum Keys {
        static let useTreeView = "useTreeView"
        static let favoritePorts = "favoritePorts"
        static let watchedPorts = "watchedPorts"
    }

    init() {
        useTreeView = defaults.bool(forKey: Keys.useTreeView)
        favoritePorts = Set((defaults.array(forKey: Keys.favoritePorts) as? [Int]) ?? [])
        watchedPorts = Set((defaults.array(forKey: Keys.watchedPorts) as? [Int]) ?? [])
    }

    var filteredPorts: [PortInfo] {
        let visible = ports.filter { !pendingKillIDs.contains($0.id) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return visible.sorted { $0.port < $1.port }
        }

        return visible.filter { port in
            String(port.port).contains(query) ||
                String(port.pid).contains(query) ||
                port.processName.localizedCaseInsensitiveContains(query) ||
                port.command.localizedCaseInsensitiveContains(query) ||
                port.user.localizedCaseInsensitiveContains(query)
        }
        .sorted { $0.port < $1.port }
    }

    var processGroups: [ProcessGroup] {
        Dictionary(grouping: filteredPorts, by: \.processName)
            .map { ProcessGroup(processName: $0.key, ports: $0.value) }
            .sorted {
                $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending
            }
    }

    // Each port lands in exactly one section: Favorites > Watched (non-favorite)
    // > its ProcessType category. Empty sections are dropped.
    var sections: [PortSection] {
        let visible = filteredPorts
        let byPort: (PortInfo, PortInfo) -> Bool = { $0.port < $1.port }

        let favorites = visible.filter { favoritePorts.contains($0.port) }.sorted(by: byPort)
        let watched = visible
            .filter { watchedPorts.contains($0.port) && !favoritePorts.contains($0.port) }
            .sorted(by: byPort)

        let remaining = visible.filter {
            !favoritePorts.contains($0.port) && !watchedPorts.contains($0.port)
        }
        let categories = Dictionary(grouping: remaining, by: \.processType)
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { PortSection(kind: .category($0.key), ports: $0.value.sorted(by: byPort)) }

        var result: [PortSection] = []
        if !favorites.isEmpty {
            result.append(PortSection(kind: .favorites, ports: favorites))
        }
        if !watched.isEmpty {
            result.append(PortSection(kind: .watched, ports: watched))
        }
        result.append(contentsOf: categories)
        return result
    }

    func toggleFavorite(_ port: PortInfo) {
        if favoritePorts.contains(port.port) {
            favoritePorts.remove(port.port)
        } else {
            favoritePorts.insert(port.port)
        }
    }

    func toggleWatched(_ port: PortInfo) {
        if watchedPorts.contains(port.port) {
            watchedPorts.remove(port.port)
        } else {
            watchedPorts.insert(port.port)
        }
    }

    func isFavorite(_ port: PortInfo) -> Bool {
        favoritePorts.contains(port.port)
    }

    func isWatched(_ port: PortInfo) -> Bool {
        watchedPorts.contains(port.port)
    }

    private func currentWatchedOpen(in ports: [PortInfo]) -> Set<Int> {
        Set(ports.map(\.port)).intersection(watchedPorts)
    }

    private var didSeedWatchedBaseline = false

    private func notifyWatchedChanges(_ newPorts: [PortInfo]) {
        let nowOpen = currentWatchedOpen(in: newPorts)

        // Seed the baseline on the first scan so we don't fire a burst of
        // "now open" notifications for ports already listening at launch.
        guard didSeedWatchedBaseline else {
            didSeedWatchedBaseline = true
            lastWatchedOpen = nowOpen
            return
        }

        let appeared = nowOpen.subtracting(lastWatchedOpen)
        let disappeared = lastWatchedOpen.subtracting(nowOpen)
        lastWatchedOpen = nowOpen

        guard !appeared.isEmpty || !disappeared.isEmpty else {
            return
        }

        let nameByPort = Dictionary(
            newPorts.map { ($0.port, $0.processName) },
            uniquingKeysWith: { first, _ in first }
        )

        for port in appeared.sorted() {
            let name = nameByPort[port] ?? "A process"
            NotificationManager.notify(
                title: "Port :\(port) opened",
                body: "\(name) is now listening on :\(port)"
            )
        }
        for port in disappeared.sorted() {
            NotificationManager.notify(
                title: "Port :\(port) closed",
                body: "Nothing is listening on :\(port) anymore"
            )
        }
    }

    func start() {
        guard !didStart else {
            return
        }
        didStart = true
        NotificationManager.requestAuthorization()
        startAutoRefresh()
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        autoRefreshTask = Task { @MainActor in
            var unchangedCycles = 0
            _ = await refresh()

            while !Task.isCancelled {
                let delaySeconds = adaptiveRefreshDelay(baseInterval: 3, unchangedCycles: unchangedCycles)
                try? await Task.sleep(for: .seconds(delaySeconds))
                guard !Task.isCancelled else {
                    break
                }

                let didChange = await refresh()
                unchangedCycles = didChange ? 0 : min(unchangedCycles + 1, 60)
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    @discardableResult
    func refresh() async -> Bool {
        if isRefreshing {
            hasPendingRefreshRequest = true
            return false
        }

        var didChangeAny = false

        repeat {
            hasPendingRefreshRequest = false
            isRefreshing = true

            let result = await Task.detached(priority: .utility) { [scanner] in
                Result { try scanner.scan() }
            }.value

            switch result {
            case .success(let scanned):
                didChangeAny = updatePorts(scanned) || didChangeAny
                feedback = nil
            case .failure(let error):
                feedback = "Scan failed: \(error.localizedDescription)"
            }

            isRefreshing = false
        } while hasPendingRefreshRequest

        return didChangeAny
    }

    @discardableResult
    func updatePorts(_ newPorts: [PortInfo]) -> Bool {
        pendingKillIDs = pendingKillIDs.intersection(Set(newPorts.map(\.id)))
        notifyWatchedChanges(newPorts)

        let newSet = Set(newPorts.map { "\($0.port)-\($0.pid)" })
        let oldSet = Set(ports.map { "\($0.port)-\($0.pid)" })
        guard newSet != oldSet else {
            return false
        }

        ports = newPorts.sorted { $0.port < $1.port }
        return true
    }

    private func adaptiveRefreshDelay(baseInterval: Int, unchangedCycles: Int) -> Double {
        let base = Double(baseInterval)
        let multiplier: Double

        switch unchangedCycles {
        case 0..<6:
            multiplier = 1.0
        case 6..<12:
            multiplier = 1.5
        default:
            multiplier = 2.0
        }

        return min(base * multiplier, 30.0)
    }

    func killPort(_ port: PortInfo) {
        pendingKillIDs.insert(port.id)
        feedback = "Killing \(port.displayPort)..."

        Task {
            let result = await Task.detached(priority: .userInitiated) { [killer] in
                killer.kill(port)
            }.value

            pendingKillIDs.remove(port.id)
            feedback = feedbackMessage(for: result, port: port)
            _ = await refresh()
        }
    }

    func killAllVisiblePorts() {
        let targets = filteredPorts
        guard !targets.isEmpty else {
            return
        }

        pendingKillIDs.formUnion(targets.map(\.id))
        feedback = "Killing \(targets.count) processes..."

        Task {
            for port in targets {
                _ = await Task.detached(priority: .userInitiated) { [killer] in
                    killer.kill(port)
                }.value
            }

            pendingKillIDs.subtract(targets.map(\.id))
            feedback = "Killed \(targets.count) processes"
            _ = await refresh()
        }
    }

    private func feedbackMessage(for result: KillResult, port: PortInfo) -> String {
        switch result {
        case .success:
            return "Killed \(port.displayPort)"
        case .alreadyExited:
            return "Already stopped \(port.displayPort)"
        case .permissionDenied:
            return "Permission denied for PID \(port.pid)"
        case .timedOut:
            return "Timed out killing PID \(port.pid)"
        case .failed(let message):
            return "Kill failed: \(message)"
        }
    }
}

@main
struct PortKillerMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: state)
                .onAppear {
                    appDelegate.state = state
                    state.start()
                    Task {
                        await state.refresh()
                    }
                }
        } label: {
            Image(nsImage: menuBarIcon())
        }
        .menuBarExtraStyle(.window)
    }

    private func menuBarIcon() -> NSImage {
        let image = NSImage(systemSymbolName: "network", accessibilityDescription: "PortKiller") ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarView: View {
    @ObservedObject var state: AppState
    @State private var confirmingKillAll = false
    @State private var confirmingKillPort: String?
    @State private var expandedProcesses = Set<String>()

    var body: some View {
        ZStack {
            GlassMaterialView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                MenuBarHeader(searchText: $state.searchText, portCount: state.filteredPorts.count)

                Divider()

                MenuBarPortList(
                    ports: state.filteredPorts,
                    sections: state.sections,
                    groups: state.processGroups,
                    useTreeView: state.useTreeView,
                    expandedProcesses: $expandedProcesses,
                    confirmingKillPort: $confirmingKillPort,
                    state: state
                )

                Divider()

                MenuBarActions(
                    confirmingKillAll: $confirmingKillAll,
                    state: state
                )
            }
        }
        .frame(width: 340)
        .background(Color.clear)
    }
}

struct GlassMaterialView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = true
    }
}

struct MenuBarHeader: View {
    @Binding var searchText: String
    let portCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.caption)

                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)

                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary)
            .cornerRadius(6)

            Text(verbatim: "\(portCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.tertiary.opacity(0.3))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct MenuBarPortList: View {
    let ports: [PortInfo]
    let sections: [PortSection]
    let groups: [ProcessGroup]
    let useTreeView: Bool
    @Binding var expandedProcesses: Set<String>
    @Binding var confirmingKillPort: String?
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if ports.isEmpty {
                    emptyState
                } else if useTreeView {
                    sectionHeader("Local Ports", icon: "network", color: .green)
                    treeView
                } else {
                    sectionListView
                }
            }
        }
        .frame(height: 400)
    }

    private var sectionListView: some View {
        ForEach(sections) { section in
            sectionHeader(
                section.title,
                icon: section.icon,
                color: color(for: section.kind),
                count: section.ports.count
            )

            ForEach(section.ports) { port in
                MenuBarPortRow(port: port, state: state, confirmingKill: $confirmingKillPort)
            }
        }
    }

    private func color(for kind: PortSectionKind) -> Color {
        switch kind {
        case .favorites:
            return .yellow
        case .watched:
            return .blue
        case .category(let type):
            return type.tint
        }
    }

    private func sectionHeader(_ title: String, icon: String, color: Color, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)

            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Spacer()

            if let count {
                Text(verbatim: "\(count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text("No open ports")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var treeView: some View {
        ForEach(groups) { group in
            MenuBarProcessGroupRow(
                group: group,
                isExpanded: expandedProcesses.contains(group.id),
                onToggleExpand: {
                    if expandedProcesses.contains(group.id) {
                        expandedProcesses.remove(group.id)
                    } else {
                        expandedProcesses.insert(group.id)
                    }
                },
                onKillProcess: {
                    group.ports.forEach(state.killPort)
                },
                state: state,
                confirmingKillPort: $confirmingKillPort
            )
        }
    }
}

struct MenuBarPortRow: View {
    let port: PortInfo
    @ObservedObject var state: AppState
    @Binding var confirmingKill: String?

    @State private var isHovered = false

    var body: some View {
        if confirmingKill == port.id {
            confirmRow
        } else {
            row
        }
    }

    private var isFavorite: Bool { state.isFavorite(port) }
    private var isWatched: Bool { state.isWatched(port) }

    private var row: some View {
        HStack(spacing: 10) {
            Image(systemName: port.processType.iconName)
                .font(.caption)
                .foregroundStyle(port.processType.tint)
                .frame(width: 16)
                .opacity(port.isActive ? 1 : 0.4)

            Text(verbatim: port.displayPort)
                .font(.system(.headline, design: .monospaced))
                .fontWeight(.semibold)
                .frame(width: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: port.processName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(verbatim: "PID \(port.pid)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                state.toggleFavorite(port)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(isFavorite || isHovered ? 1 : 0)
            .help("Favorite")

            Button {
                state.toggleWatched(port)
            } label: {
                Image(systemName: isWatched ? "eye.fill" : "eye")
                    .foregroundStyle(isWatched ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(isWatched || isHovered ? 1 : 0)
            .help("Watch")

            Button {
                confirmingKill = port.id
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Kill Process", role: .destructive) {
                state.killPort(port)
            }
            Button(isFavorite ? "Remove Favorite" : "Add Favorite") {
                state.toggleFavorite(port)
            }
            Button(isWatched ? "Unwatch Port" : "Watch Port") {
                state.toggleWatched(port)
            }
            Divider()
            Text("User: \(port.user)")
            Text("FD: \(port.fd)")
            Text(port.address)
        }
    }

    private var confirmRow: some View {
        HStack(spacing: 8) {
            Text("Kill \(port.displayPort)?")
                .font(.callout)
                .fontWeight(.medium)

            Spacer()

            Button("Kill") {
                confirmingKill = nil
                state.killPort(port)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)

            Button("Cancel") {
                confirmingKill = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

struct MenuBarProcessGroupRow: View {
    let group: ProcessGroup
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onKillProcess: () -> Void
    @ObservedObject var state: AppState
    @Binding var confirmingKillPort: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggleExpand) {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .frame(width: 12)

                        Image(systemName: group.ports.first?.processType.iconName ?? "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(group.processName)
                            .font(.callout)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(group.ports.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button(action: onKillProcess) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            if isExpanded {
                ForEach(group.ports) { port in
                    MenuBarPortRow(port: port, state: state, confirmingKill: $confirmingKillPort)
                        .padding(.leading, 20)
                }
            }
        }
    }
}

struct MenuBarActions: View {
    @Binding var confirmingKillAll: Bool
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            MenuItemButton(
                title: state.isRefreshing ? "Refreshing..." : "Refresh",
                icon: "arrow.clockwise",
                shortcut: "R"
            ) {
                Task {
                    await state.refresh()
                }
            }
            .disabled(state.isRefreshing)

            MenuItemButton(
                title: state.useTreeView ? "List View" : "Tree View",
                icon: state.useTreeView ? "list.bullet" : "list.bullet.indent",
                shortcut: "T"
            ) {
                state.useTreeView.toggle()
            }

            if confirmingKillAll {
                HStack {
                    Text("Kill all \(state.filteredPorts.count) processes?")
                        .font(.callout)

                    Spacer()

                    Button("Kill") {
                        state.killAllVisiblePorts()
                        confirmingKillAll = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)

                    Button("Cancel") {
                        confirmingKillAll = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else {
                MenuItemButton(title: "Kill All", icon: "xmark.circle", shortcut: "K", isDestructive: true) {
                    confirmingKillAll = true
                }
                .disabled(state.filteredPorts.isEmpty)
            }

            Divider()
                .padding(.vertical, 4)

            MenuItemButton(title: "Quit PortKiller", icon: "power", shortcut: "Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MenuItemButton: View {
    let title: String
    let icon: String
    var shortcut: String? = nil
    var isDestructive = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(verbatim: "⌘\(shortcut)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .foregroundStyle(isDestructive ? .red : .primary)
            .background(isHovered ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
