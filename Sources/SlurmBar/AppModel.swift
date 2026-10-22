import Foundation
import Observation
import SlurmBarCore

@MainActor
@Observable
final class AppModel {
    var hosts: [SSHHost] = [] {
        didSet {
            configurationRevision += 1
            save()
        }
    }
    // Selection is deliberately session-only: every launch starts without a host.
    var selectedAlias = "" {
        didSet {
            configurationRevision += 1
            activeHosts.removeAll()
            guard !selectedAlias.isEmpty else { return }
            if !hosts.contains(where: { $0.alias == selectedAlias }),
               let found = discoveries.first(where: { $0.alias == selectedAlias }), let path = found.controlPath {
                hosts.append(SSHHost(alias: selectedAlias, controlPath: path))
            }
        }
    }
    var selectedHost: SSHHost? {
        hosts.first { $0.alias == selectedAlias }
    }
    var selectedDiscovery: DiscoveredHost? {
        discoveries.first { $0.alias == selectedAlias }
    }
    var snapshots: [UUID: ClusterSnapshot] = [:]
    var statuses: [UUID: String] = [:]
    var activeHosts: Set<UUID> = []
    var discoveries: [DiscoveredHost] = []
    var partitionNames: [String: [String]] = [:]
    var refreshInterval: Double = 60 {
        didSet { defaults.set(max(30, refreshInterval), forKey: "refreshInterval") }
    }
    private let defaults: UserDefaults
    private let transport = SSHTransport()
    @ObservationIgnored private lazy var collector = SlurmCollector(transport: transport)
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var nextRefresh: [UUID: Date] = [:]
    @ObservationIgnored private var lastQueryAttempt: [UUID: Date] = [:]
    @ObservationIgnored private var failures: [UUID: Int] = [:]
    @ObservationIgnored private var configurationRevision = 0
    @ObservationIgnored private var isRefreshing = false
    // Socket recovery invalidates the displayed data, but must not restart its expiry clock.
    @ObservationIgnored private var lastSnapshotAt: [UUID: Date] = [:]

    @ObservationIgnored private var discoveryGeneration = 0

    init(defaults: UserDefaults = .standard, startMonitoring: Bool = true,
         discover: @escaping @Sendable () async -> [DiscoveredHost] = { await HostDiscovery.discoverInBackground() }) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "hosts"), let saved = try? JSONDecoder().decode([SSHHost].self, from: data) { hosts = saved }
        let savedInterval = defaults.double(forKey: "refreshInterval")
        refreshInterval = savedInterval >= 30 ? savedInterval : 60
        if let data = defaults.data(forKey: "partitionNames"), let saved = try? JSONDecoder().decode([String: [String]].self, from: data) { partitionNames = saved }
        guard startMonitoring else { return }
        loop = Task { [weak self] in
            await self?.reloadDiscoveries(discover: discover)
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.tick()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    deinit { loop?.cancel() }

    func stopMonitoring() async {
        loop?.cancel()
        await loop?.value
        loop = nil
    }

    var menuTitle: String {
        guard let host = selectedHost, host.enabled, isSnapshotCurrent(host.id),
              let snapshot = snapshots[host.id] else { return "Slurm" }
        return "Slurm \(snapshot.uniqueIdleNodeCount) idle"
    }

    func isSnapshotCurrent(_ id: UUID) -> Bool {
        guard selectedHost?.id == id, selectedHost?.enabled == true, activeHosts.contains(id), statuses[id] == "Connected", let snapshot = snapshots[id] else { return false }
        return Date().timeIntervalSince(snapshot.updatedAt) <= max(30, refreshInterval) * 2
    }

    func reloadDiscoveries(discover: @Sendable () async -> [DiscoveredHost] = { await HostDiscovery.discoverInBackground() }) async {
        discoveryGeneration += 1
        let generation = discoveryGeneration
        let found = await discover()
        guard !Task.isCancelled, generation == discoveryGeneration else { return }
        discoveries = found
        if !selectedAlias.isEmpty && !discoveries.contains(where: { $0.alias == selectedAlias }) { selectedAlias = "" }
    }

    func refreshSelectedControlPathIfNeeded(resolve: @escaping @Sendable (String) -> DiscoveredHost = { HostDiscovery.resolve(alias: $0) }) async {
        guard let host = selectedHost, host.enabled else { return }
        // Socket validation and configuration reads both run off the UI thread.
        let found = await HostDiscovery.replacementInBackground(for: host, resolve: resolve)
        guard !Task.isCancelled, selectedHost == host, let found, let path = found.controlPath else { return }
        if let index = discoveries.firstIndex(where: { $0.alias == host.alias }) {
            discoveries[index] = found
        }
        configure(alias: host.alias, path: path)
    }

    func configure(alias: String, path: String) {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard discoveries.contains(where: { $0.alias == alias }), path.hasPrefix("/") else { return }
        if let index = hosts.firstIndex(where: { $0.alias == alias }) {
            let id = hosts[index].id
            hosts[index].controlPath = path
            if let snapshot = snapshots[id] { lastSnapshotAt[id] = snapshot.updatedAt }
            snapshots[id] = nil
            activeHosts.remove(id)
            statuses[id] = "Waiting for an external SSH session"
            if (failures[id] ?? 0) == 0 { nextRefresh[id] = nil }
        } else {
            hosts.append(SSHHost(alias: alias, controlPath: path))
        }
    }

    func requestRefresh() {
        // Respect a minimum interval even for repeated clicks.
        if let host = selectedHost {
            // Manual refresh cannot bypass failure backoff.
            guard (failures[host.id] ?? 0) == 0 else { return }
            if let updated = snapshots[host.id]?.updatedAt, Date().timeIntervalSince(updated) < 30 { return }
            nextRefresh[host.id] = .distantPast
        }
    }

    func updatePartitions(_ value: String, hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        let names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard names != hosts[index].selectedPartitions else { return }
        hosts[index].selectedPartitions = names
        statuses[hostID] = "Partition selection changed — refresh pending"
        if (failures[hostID] ?? 0) == 0 {
            nextRefresh[hostID] = snapshots[hostID]?.updatedAt.addingTimeInterval(30) ?? .distantPast
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) { defaults.set(data, forKey: "hosts") }
    }

    // Shared by every refresh trigger; timestamps also allow deterministic throttling tests.
    func beginRefresh(hostID: UUID, now: Date = Date()) -> Bool {
        guard now >= (nextRefresh[hostID] ?? .distantPast),
              now.timeIntervalSince(lastQueryAttempt[hostID] ?? .distantPast) >= 30 else { return false }
        lastQueryAttempt[hostID] = now
        return true
    }

    func finishRefresh(hostID: UUID, succeeded: Bool, now: Date = Date()) {
        let count = succeeded ? 0 : min((failures[hostID] ?? 0) + 1, 4)
        failures[hostID] = count
        let multiplier = succeeded ? 1 : pow(2, Double(count - 1))
        nextRefresh[hostID] = now.addingTimeInterval(max(30, refreshInterval) * multiplier)
    }

    func expireDisconnectedSnapshot(now: Date = Date()) {
        guard let host = selectedHost, !activeHosts.contains(host.id),
              let updated = snapshots[host.id]?.updatedAt ?? lastSnapshotAt[host.id],
              now.timeIntervalSince(updated) > 3600 else { return }
        selectedAlias = ""
        snapshots.removeAll()
        statuses.removeAll()
        partitionNames.removeAll()
        lastSnapshotAt.removeAll()
        defaults.removeObject(forKey: "partitionNames")
        // Retain attempt timestamps and backoff so selecting the host again cannot bypass them.
    }

    func tick(now: () -> Date = { Date() },
              availability: ((SSHHost) async -> SessionAvailability)? = nil) async {
        // Recover before publishing an absent-socket status, then check the new
        // socket's external channels in this same monitoring cycle.
        await refreshSelectedControlPathIfNeeded()
        guard !Task.isCancelled else { return }
        if let host = selectedHost {
            guard host.enabled else {
                statuses[host.id] = "Querying paused"
                activeHosts.remove(host.id)
                return
            }
            let availability = if let availability {
                await availability(host)
            } else {
                await transport.availability(for: host)
            }
            guard !Task.isCancelled, selectedHost == host else { return }
            switch availability {
            case .active:
                activeHosts.insert(host.id)
            case .inactive:
                statuses[host.id] = "Waiting for an external SSH session"
                activeHosts.remove(host.id)
                if (failures[host.id] ?? 0) == 0 { nextRefresh[host.id] = nil }
                expireDisconnectedSnapshot(now: now())
                return
            case .unsupported:
                statuses[host.id] = "SSH channel inspection unsupported — monitoring paused"
                activeHosts.remove(host.id)
                expireDisconnectedSnapshot(now: now())
                return
            case .unavailable(let message):
                statuses[host.id] = message
                activeHosts.remove(host.id)
                if (failures[host.id] ?? 0) == 0 { nextRefresh[host.id] = nil }
                expireDisconnectedSnapshot(now: now())
                return
            }
            await refresh(host: host) { try await self.collector.collect(host: $0) }
        }
    }

    // Keep scheduling independent of whether a result still belongs to the UI.
    // The injected collector/clock also allow suspension and backoff tests without SSH.
    func refresh(host: SSHHost, now: () -> Date = { Date() },
                 collect: @MainActor (SSHHost) async throws -> ClusterSnapshot) async {
        guard !Task.isCancelled, !isRefreshing, host.enabled, selectedHost == host,
              beginRefresh(hostID: host.id, now: now()) else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let revision = configurationRevision
        statuses[host.id] = "Refreshing…"
        do {
            let snapshot = try await collect(host)
            finishRefresh(hostID: host.id, succeeded: snapshot.jobsWarning == nil && snapshot.pendingWarning == nil, now: now())
            guard !Task.isCancelled, configurationRevision == revision, selectedHost == host else { return }
            snapshots[host.id] = snapshot
            lastSnapshotAt[host.id] = snapshot.updatedAt
            partitionNames[host.id.uuidString] = snapshot.availablePartitionNames
            if let data = try? JSONEncoder().encode(partitionNames) { defaults.set(data, forKey: "partitionNames") }
            statuses[host.id] = "Connected"
        } catch {
            // Shutdown cancellation is not a failed scheduler query.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            finishRefresh(hostID: host.id, succeeded: false, now: now())
            guard configurationRevision == revision, selectedHost == host else { return }
            statuses[host.id] = error.localizedDescription
            activeHosts.remove(host.id)
        }
    }
}
