import Foundation
import Combine
import SlurmBarCore

@MainActor
final class AppModel: ObservableObject {
    @Published var hosts: [SSHHost] = [] { didSet { save() } }
    @Published var snapshots: [UUID: ClusterSnapshot] = [:]
    @Published var statuses: [UUID: String] = [:]
    @Published var activeHosts: Set<UUID> = []
    @Published var discoveries: [DiscoveredHost] = []
    @Published var partitionNames: [String: [String]] = [:]
    @Published var refreshInterval: Double = 60 {
        didSet { UserDefaults.standard.set(max(30, refreshInterval), forKey: "refreshInterval") }
    }
    private let transport = SSHTransport()
    private lazy var collector = SlurmCollector(transport: transport)
    private var loop: Task<Void, Never>?
    private var nextRefresh: [UUID: Date] = [:]
    private var failures: [UUID: Int] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: "hosts"), let saved = try? JSONDecoder().decode([SSHHost].self, from: data) { hosts = saved }
        let savedInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = savedInterval >= 30 ? savedInterval : 60
        if let data = UserDefaults.standard.data(forKey: "partitionNames"), let saved = try? JSONDecoder().decode([String: [String]].self, from: data) { partitionNames = saved }
        discoveries = HostDiscovery.discover()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    var menuTitle: String {
        let live = hosts.filter { $0.enabled && isSnapshotCurrent($0.id) }.compactMap { snapshots[$0.id] }
        guard !live.isEmpty else { return "Slurm" }
        // A node may occur in multiple partitions: count each host/node only once.
        let idle = live.reduce(0) { $0 + $1.uniqueIdleNodeCount }
        return "Slurm \(idle) idle"
    }

    func isSnapshotCurrent(_ id: UUID) -> Bool {
        guard activeHosts.contains(id), statuses[id] == "Connected", let snapshot = snapshots[id] else { return false }
        return Date().timeIntervalSince(snapshot.updatedAt) <= max(30, refreshInterval) * 2
    }

    func reloadDiscoveries() {
        discoveries = HostDiscovery.discover()
    }

    func detectControlPath(for id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        let result = HostDiscovery.resolve(alias: hosts[index].alias)
        guard let path = result.controlPath else {
            statuses[id] = result.resolutionIssue ?? "ControlPath could not be resolved"
            return
        }
        hosts[index].controlPath = path
        snapshots[id] = nil
        activeHosts.remove(id)
        statuses[id] = "ControlPath resolved locally — waiting for an external SSH session"
        nextRefresh[id] = nil
    }

    func add(alias: String, path: String) {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard HostDiscovery.isSafeAlias(alias), path.hasPrefix("/"), !hosts.contains(where: { $0.alias == alias && $0.controlPath == path }) else { return }
        hosts.append(SSHHost(alias: alias, controlPath: path))
    }

    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        snapshots[id] = nil
        statuses[id] = nil
        activeHosts.remove(id)
    }

    func requestRefresh() {
        // Respect a minimum interval even for repeated clicks.
        for host in hosts {
            if let updated = snapshots[host.id]?.updatedAt, Date().timeIntervalSince(updated) < 30 { continue }
            nextRefresh[host.id] = .distantPast
        }
    }

    func updatePartitions(_ value: String, hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        let names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard names != hosts[index].selectedPartitions else { return }
        hosts[index].selectedPartitions = names
        statuses[hostID] = "Partition selection changed — refresh pending"
        nextRefresh[hostID] = snapshots[hostID]?.updatedAt.addingTimeInterval(30) ?? .distantPast
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(data, forKey: "hosts") }
    }

    private func tick() async {
        for host in hosts {
            guard host.enabled else {
                statuses[host.id] = "Disabled"
                activeHosts.remove(host.id)
                continue
            }
            let availability = await transport.availability(for: host)
            guard hosts.contains(where: { $0 == host }) else { continue }
            switch availability {
            case .active:
                activeHosts.insert(host.id)
            case .inactive:
                statuses[host.id] = "Waiting for an external SSH session"
                activeHosts.remove(host.id)
                nextRefresh[host.id] = nil
                continue
            case .unsupported:
                statuses[host.id] = "SSH channel inspection unsupported — monitoring paused"
                activeHosts.remove(host.id)
                continue
            case .unavailable(let message):
                statuses[host.id] = message
                activeHosts.remove(host.id)
                nextRefresh[host.id] = nil
                continue
            }
            guard Date() >= (nextRefresh[host.id] ?? .distantPast) else { continue }
            statuses[host.id] = "Refreshing…"
            do {
                let snapshot = try await collector.collect(host: host)
                guard hosts.contains(where: { $0 == host }) else { continue }
                snapshots[host.id] = snapshot
                partitionNames[host.id.uuidString] = snapshot.availablePartitionNames
                if let data = try? JSONEncoder().encode(partitionNames) { UserDefaults.standard.set(data, forKey: "partitionNames") }
                statuses[host.id] = "Connected"
                failures[host.id] = 0
                nextRefresh[host.id] = Date().addingTimeInterval(max(30, refreshInterval))
            } catch {
                statuses[host.id] = error.localizedDescription
                activeHosts.remove(host.id)
                let count = min((failures[host.id] ?? 0) + 1, 4)
                failures[host.id] = count
                nextRefresh[host.id] = Date().addingTimeInterval(max(30, refreshInterval) * pow(2, Double(count - 1)))
            }
        }
    }
}
