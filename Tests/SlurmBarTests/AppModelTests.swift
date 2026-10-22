import Foundation
import Darwin
import Testing
import Observation
import os
import SlurmBarCore
@testable import SlurmBar

@MainActor
struct AppModelTests {
    private func withSocket(_ body: @MainActor (String) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: "/tmp/sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("master").path
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        try await body(path)
    }

    private func withModel(_ body: @MainActor (AppModel, UserDefaults) async throws -> Void) async throws {
        let suite = "SlurmBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(AppModel(defaults: defaults, startMonitoring: false), defaults)
    }

    private actor DiscoveryGate {
        private var result: CheckedContinuation<[DiscoveredHost], Never>?
        private var started: CheckedContinuation<Void, Never>?
        private var isStarted = false

        func discover() async -> [DiscoveredHost] {
            await withCheckedContinuation { continuation in
                result = continuation
                isStarted = true
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if !isStarted {
                await withCheckedContinuation { started = $0 }
            }
        }

        func finish(_ hosts: [DiscoveredHost]) {
            result?.resume(returning: hosts)
            result = nil
        }
    }

    @Test func newerDiscoveryWinsWhenOlderReadFinishesLast() async throws {
        try await withModel { model, _ in
            let gate = DiscoveryGate()
            let old = Task { await model.reloadDiscoveries { await gate.discover() } }
            await gate.waitUntilStarted()
            let current = DiscoveredHost(alias: "current", controlPath: "/tmp/current")
            await model.reloadDiscoveries { [current] }
            model.selectedAlias = current.alias
            await gate.finish([DiscoveredHost(alias: "obsolete", controlPath: "/tmp/obsolete")])
            await old.value
            #expect(model.discoveries == [current])
            #expect(model.selectedAlias == current.alias)
        }
    }

    @Test func cancelledDiscoveryDoesNotPublishResults() async throws {
        try await withModel { model, _ in
            let gate = DiscoveryGate()
            let read = Task { await model.reloadDiscoveries { await gate.discover() } }
            await gate.waitUntilStarted()
            read.cancel()
            await gate.finish([DiscoveredHost(alias: "obsolete", controlPath: "/tmp/obsolete")])
            await read.value
            #expect(model.discoveries.isEmpty)
        }
    }

    @Test func shutdownCancelsMonitoringAndDiscardsItsDiscovery() async throws {
        let suite = "SlurmBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = AsyncStream<Void>.makeStream()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let model = AppModel(defaults: defaults, discover: {
            started.continuation.yield(())
            do { try await Task.sleep(for: .seconds(5)) }
            catch { cancelled.withLock { $0 = Task.isCancelled } }
            return [DiscoveredHost(alias: "obsolete", controlPath: "/tmp/obsolete")]
        })
        for await _ in started.stream { break }
        await model.stopMonitoring()
        #expect(cancelled.withLock { $0 })
        #expect(model.discoveries.isEmpty)
        await model.stopMonitoring()
    }

    @Test func pollingDoesNotKeepAnUnownedModelAlive() async throws {
        let suite = "SlurmBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = AsyncStream<Void>.makeStream()
        var model: AppModel? = AppModel(defaults: defaults, discover: {
            started.continuation.yield(())
            return []
        })
        for await _ in started.stream { break }
        let isReleased = { [weak model] in model == nil }
        model = nil
        // Let the initial lookup/tick release its temporary strong reference.
        for _ in 0..<100 {
            if isReleased() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(isReleased())
    }

    @Test func observationTracksComputedTitleAndNestedHostChanges() async throws {
        try await withModel { model, defaults in
            let host = SSHHost(alias: "cluster", controlPath: "/tmp/socket")
            model.hosts = [host]
            model.selectedAlias = host.alias
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = model.menuTitle
            } onChange: {
                changed.withLock { $0 = true }
            }
            model.hosts[0].enabled = false
            #expect(changed.withLock { $0 })
            let saved = try JSONDecoder().decode([SSHHost].self, from: #require(defaults.data(forKey: "hosts")))
            #expect(saved.first?.enabled == false)
        }
    }

    @Test func backgroundRecoveryCannotOverwriteAnEditedSocket() async throws {
        try await withSocket { path in
            try await withModel { model, _ in
                let host = SSHHost(alias: "cluster", controlPath: "/missing")
                model.hosts = [host]
                model.discoveries = [DiscoveredHost(alias: host.alias, controlPath: host.controlPath)]
                model.selectedAlias = host.alias
                let started = AsyncStream<Void>.makeStream()
                let resume = DispatchSemaphore(value: 0)
                let read = Task {
                    await model.refreshSelectedControlPathIfNeeded { alias in
                        #expect(!Thread.isMainThread)
                        started.continuation.yield(())
                        #expect(resume.wait(timeout: .now() + 5) == .success)
                        return DiscoveredHost(alias: alias, controlPath: path)
                    }
                }
                for await _ in started.stream { break }
                model.configure(alias: host.alias, path: "/manual/override")
                resume.signal()
                await read.value
                #expect(model.selectedHost?.controlPath == "/manual/override")
            }
        }
    }

    private actor RefreshGate {
        private var result: CheckedContinuation<ClusterSnapshot, any Error>?
        private var started: CheckedContinuation<Void, Never>?
        private var isStarted = false

        func collect() async throws -> ClusterSnapshot {
            try await withCheckedThrowingContinuation { continuation in
                result = continuation
                isStarted = true
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if !isStarted {
                await withCheckedContinuation { started = $0 }
            }
        }

        func finish(_ outcome: Result<ClusterSnapshot, any Error>) {
            result?.resume(with: outcome)
            result = nil
        }
    }

    @Test(arguments: ["selection", "socket", "partitions", "pause", "roundTrip"], [false, true])
    func completedRefreshKeepsSchedulingAfterConfigurationChanges(change: String, failed: Bool) async throws {
        try await withModel { model, _ in
            let host = SSHHost(alias: "cluster", controlPath: "/tmp/socket")
            let other = SSHHost(alias: "other", controlPath: "/tmp/other")
            model.hosts = [host, other]
            model.discoveries = [DiscoveredHost(alias: host.alias, controlPath: host.controlPath)]
            model.selectedAlias = host.alias
            let now = Date(timeIntervalSince1970: 100_000)
            // The suspended attempt will either recover or become a second failure.
            let previous = now.addingTimeInterval(-60)
            #expect(model.beginRefresh(hostID: host.id, now: previous))
            model.finishRefresh(hostID: host.id, succeeded: false, now: previous)
            let gate = RefreshGate()
            let query = Task {
                await model.refresh(host: host, now: { now }) { _ in try await gate.collect() }
            }
            await gate.waitUntilStarted()
            switch change {
            case "selection": model.selectedAlias = other.alias
            case "socket": model.configure(alias: host.alias, path: "/tmp/new")
            case "partitions": model.updatePartitions("gpu", hostID: host.id)
            case "pause": model.hosts[0].enabled = false
            default:
                // Equality alone misses an edit that was subsequently reverted.
                model.updatePartitions("gpu", hostID: host.id)
                model.updatePartitions("", hostID: host.id)
            }
            let statusAfterEdit = model.statuses[host.id]
            if failed {
                await gate.finish(.failure(SlurmError.commandFailed(1, "test failure")))
            } else {
                await gate.finish(.success(ClusterSnapshot(partitions: [], jobs: [])))
            }
            await query.value
            #expect(model.snapshots[host.id] == nil)
            #expect(model.partitionNames[host.id.uuidString] == nil)
            #expect(model.statuses[host.id] == statusAfterEdit)
            // Selecting the host again must retain its schedule; clicks cannot bypass failure backoff.
            model.selectedAlias = host.alias
            if failed { model.requestRefresh() }
            let delay = failed ? 120.0 : 60.0
            #expect(!model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(delay - 1)))
            #expect(model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(delay)))
        }
    }

    @Test func unchangedRefreshPublishesSnapshotAndRetainsNormalInterval() async throws {
        try await withModel { model, _ in
            let host = SSHHost(alias: "cluster", controlPath: "/tmp/socket")
            model.hosts = [host]
            model.selectedAlias = host.alias
            let now = Date(timeIntervalSince1970: 100_000)
            let snapshot = ClusterSnapshot(partitions: [], jobs: [], updatedAt: now)
            await model.refresh(host: host, now: { now }) { _ in snapshot }
            #expect(model.snapshots[host.id]?.updatedAt == now)
            #expect(model.statuses[host.id] == "Connected")
            #expect(!model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(59)))
            #expect(model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(60)))
        }
    }

    @Test func suspendedRefreshPreventsOverlappingQueries() async throws {
        try await withModel { model, _ in
            let host = SSHHost(alias: "cluster", controlPath: "/tmp/socket")
            model.hosts = [host]
            model.selectedAlias = host.alias
            let now = Date(timeIntervalSince1970: 100_000)
            let gate = RefreshGate()
            let first = Task {
                await model.refresh(host: host, now: { now }) { _ in try await gate.collect() }
            }
            await gate.waitUntilStarted()
            await model.refresh(host: host, now: { now.addingTimeInterval(30) }) { _ in
                Issue.record("A second query must not start while the first is suspended")
                return ClusterSnapshot(partitions: [], jobs: [])
            }
            await gate.finish(.success(ClusterSnapshot(partitions: [], jobs: [])))
            await first.value
            #expect(model.statuses[host.id] == "Connected")
        }
    }

    @Test func launchStartsEmptyDespiteSavedHosts() async throws {
        try await withModel { model, defaults in
            let host = SSHHost(alias: "cluster", controlPath: "/tmp/socket")
            model.hosts = [host]
            model.selectedAlias = "cluster"
            let relaunched = AppModel(defaults: defaults, startMonitoring: false)
            #expect(relaunched.selectedAlias.isEmpty)
            #expect(relaunched.selectedHost == nil)
            #expect(relaunched.hosts == [host])
            #expect(relaunched.menuTitle == "Slurm")
        }
    }

    @Test(arguments: [SessionAvailability.inactive, .unsupported, .unavailable("Socket absent")],
          [3599.0, 3600, 3601])
    func disconnectedSnapshotExpiresOnlyAfterOneHour(availability: SessionAvailability, age: Double) async throws {
        try await withModel { model, defaults in
            let host = SSHHost(alias: "cluster", controlPath: "/missing", selectedPartitions: ["gpu"])
            model.hosts = [host]
            model.selectedAlias = host.alias
            let now = Date()
            model.snapshots[host.id] = ClusterSnapshot(partitions: [], jobs: [], updatedAt: now.addingTimeInterval(-age))
            model.partitionNames[host.id.uuidString] = ["gpu"]
            defaults.set(try JSONEncoder().encode(model.partitionNames), forKey: "partitionNames")
            model.activeHosts = [host.id]
            #expect(model.beginRefresh(hostID: host.id, now: now))
            model.finishRefresh(hostID: host.id, succeeded: false, now: now)
            await model.tick(now: { now }, availability: { _ in availability })
            if age > 3600 {
                #expect(model.selectedAlias.isEmpty)
                #expect(model.selectedHost == nil)
                #expect(model.snapshots.isEmpty)
                #expect(model.statuses.isEmpty)
                #expect(model.activeHosts.isEmpty)
                #expect(model.partitionNames.isEmpty)
                #expect(defaults.data(forKey: "partitionNames") == nil)
                #expect(model.hosts == [host])
                model.selectedAlias = host.alias
                model.requestRefresh()
                #expect(!model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(59)))
                #expect(model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(60)))
            } else {
                #expect(model.selectedHost == host)
                #expect(model.snapshots[host.id] != nil)
                #expect(model.partitionNames[host.id.uuidString] == ["gpu"])
            }
        }
    }

    @Test func activeSessionKeepsOldSnapshotAndSelection() async throws {
        try await withModel { model, _ in
            let host = SSHHost(alias: "cluster", controlPath: "/missing")
            model.hosts = [host]
            model.selectedAlias = host.alias
            let now = Date()
            model.snapshots[host.id] = ClusterSnapshot(partitions: [], jobs: [], updatedAt: now.addingTimeInterval(-7200))
            // Keep the next scheduler query pending while checking the restored session.
            model.finishRefresh(hostID: host.id, succeeded: true, now: now)
            await model.tick(now: { now }, availability: { _ in .active })
            #expect(model.selectedHost == host)
            #expect(model.activeHosts.contains(host.id))
            #expect(model.snapshots[host.id] != nil)
        }
    }

    @Test func socketReconfigurationPreservesSnapshotExpiry() async throws {
        try await withModel { model, _ in
            let host = SSHHost(alias: "cluster", controlPath: "/missing")
            model.hosts = [host]
            model.discoveries = [DiscoveredHost(alias: host.alias, controlPath: host.controlPath)]
            model.selectedAlias = host.alias
            let now = Date()
            model.snapshots[host.id] = ClusterSnapshot(partitions: [], jobs: [], updatedAt: now.addingTimeInterval(-3601))
            model.configure(alias: host.alias, path: "/missing/replacement")
            #expect(model.snapshots[host.id] == nil)
            await model.tick(now: { now }, availability: { _ in .inactive })
            #expect(model.selectedAlias.isEmpty)
        }
    }

    @Test func selectionAutomaticallyConfiguresOnlyChosenHost() async throws {
        try await withModel { model, _ in
            model.hosts = []
            model.discoveries = [
                DiscoveredHost(alias: "alpha", controlPath: "/tmp/alpha", controlMasterEnabled: true),
                DiscoveredHost(alias: "beta", controlPath: "/tmp/beta", controlMasterEnabled: true)
            ]
            model.selectedAlias = "beta"
            #expect(model.selectedHost?.alias == "beta")
            #expect(model.hosts.map(\.alias) == ["beta"])
            model.activeHosts = [model.selectedHost!.id]
            model.selectedAlias = ""
            #expect(model.selectedHost == nil)
            #expect(model.activeHosts.isEmpty)
        }
    }

    @Test func manualSocketOverrideUpdatesHostWithoutDuplicatesOrLosingFilters() async throws {
        try await withModel { model, _ in
            let host = SSHHost(alias: "cluster", controlPath: "/tmp/old", selectedPartitions: ["gpu"])
            model.hosts = [host]
            model.discoveries = [DiscoveredHost(alias: "cluster", controlPath: nil, controlMasterEnabled: true)]
            model.selectedAlias = "cluster"
            model.configure(alias: "cluster", path: "/tmp/new")
            #expect(model.hosts.count == 1)
            #expect(model.selectedHost?.id == host.id)
            #expect(model.selectedHost?.controlPath == "/tmp/new")
            #expect(model.selectedHost?.selectedPartitions == ["gpu"])
            model.configure(alias: "github", path: "/tmp/github")
            #expect(model.hosts.count == 1)
        }
    }

    @Test func missingSocketRecoversWhenReplacementAppearsAndPersistsSettings() async throws {
        try await withSocket { path in
            try await withModel { model, defaults in
                let host = SSHHost(alias: "cluster", controlPath: "/missing/old", selectedPartitions: ["gpu"])
                let other = SSHHost(alias: "other", controlPath: "/missing/other")
                model.hosts = [host, other]
                model.discoveries = [DiscoveredHost(alias: "cluster", controlPath: host.controlPath, controlMasterEnabled: true)]
                model.selectedAlias = host.alias
                model.statuses[host.id] = "Control socket is absent"
                let now = Date()
                #expect(model.beginRefresh(hostID: host.id, now: now))
                model.finishRefresh(hostID: host.id, succeeded: false, now: now)

                // No replacement yet: retain the path so later cycles can retry.
                await model.refreshSelectedControlPathIfNeeded { alias in
                    DiscoveredHost(alias: alias, controlPath: "/missing/new", controlMasterEnabled: true)
                }
                #expect(model.selectedHost == host)
                await model.refreshSelectedControlPathIfNeeded { alias in
                    DiscoveredHost(alias: alias, controlPath: path, controlMasterEnabled: true)
                }
                #expect(model.selectedHost?.controlPath == path)
                #expect(model.selectedHost?.id == host.id)
                #expect(model.selectedHost?.selectedPartitions == ["gpu"])
                #expect(model.hosts[1] == other)
                #expect(model.selectedDiscovery?.controlPath == path)
                #expect(model.statuses[host.id] == "Waiting for an external SSH session")
                #expect(!model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(59)))
                #expect(model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(60)))
                #expect(AppModel(defaults: defaults, startMonitoring: false).hosts == model.hosts)
            }
        }
    }

    @Test func validSocketOverrideAndPausedHostDoNotTriggerRediscovery() async throws {
        try await withSocket { path in
            try await withModel { model, _ in
                let host = SSHHost(alias: "cluster", controlPath: path)
                model.hosts = [host]
                model.selectedAlias = host.alias
                await model.refreshSelectedControlPathIfNeeded { _ in
                    Issue.record("An existing valid socket must be kept")
                    return DiscoveredHost(alias: "cluster", controlPath: "/missing")
                }
                #expect(model.selectedHost == host)
                model.hosts[0].enabled = false
                model.hosts[0].controlPath = "/missing"
                await model.refreshSelectedControlPathIfNeeded { _ in
                    Issue.record("A paused host must not trigger rediscovery")
                    return DiscoveredHost(alias: "cluster", controlPath: path)
                }
                #expect(model.selectedHost?.controlPath == "/missing")
            }
        }
    }

    @Test func replacementMustBeAValidSocketForTheSelectedAlias() async throws {
        try await withSocket { path in
            try await withModel { model, _ in
                let host = SSHHost(alias: "cluster", controlPath: "/missing")
                model.hosts = [host]
                model.discoveries = [DiscoveredHost(alias: host.alias, controlPath: host.controlPath)]
                model.selectedAlias = host.alias
                await model.refreshSelectedControlPathIfNeeded { _ in
                    DiscoveredHost(alias: "other", controlPath: path)
                }
                #expect(model.selectedHost == host)
                let file = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("regular-file")
                try Data().write(to: file)
                await model.refreshSelectedControlPathIfNeeded { alias in
                    DiscoveredHost(alias: alias, controlPath: file.path)
                }
                #expect(model.selectedHost == host)
            }
        }
    }

    @Test func refreshClicksAndReconfigurationCannotBypassMinimumInterval() async throws {
        try await withModel { model, _ in
            let host = SSHHost(alias: "cluster", controlPath: "/tmp/socket")
            model.hosts = [host]
            model.discoveries = [DiscoveredHost(alias: "cluster", controlPath: "/tmp/socket", controlMasterEnabled: true)]
            model.selectedAlias = "cluster"
            let now = Date()
            #expect(model.beginRefresh(hostID: host.id, now: now))
            for _ in 0..<20 { model.requestRefresh() }
            model.configure(alias: "cluster", path: "/tmp/new")
            model.updatePartitions("cpu", hostID: host.id)
            #expect(!model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(29)))
            #expect(model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(30)))
        }
    }

    @Test func failedRefreshBackoffSurvivesClicksAndConfigurationChanges() async throws {
        try await withModel { model, _ in
            let host = SSHHost(alias: "cluster", controlPath: "/tmp/socket")
            model.hosts = [host]
            model.discoveries = [DiscoveredHost(alias: "cluster", controlPath: "/tmp/socket", controlMasterEnabled: true)]
            model.selectedAlias = "cluster"
            model.refreshInterval = 60
            var now = Date()
            for delay in [60.0, 120, 240, 480, 480] {
                #expect(model.beginRefresh(hostID: host.id, now: now))
                model.finishRefresh(hostID: host.id, succeeded: false, now: now)
                model.requestRefresh()
                model.configure(alias: "cluster", path: "/tmp/new")
                model.updatePartitions(UUID().uuidString, hostID: host.id)
                #expect(!model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(delay - 1)))
                now = now.addingTimeInterval(delay)
            }
            #expect(model.beginRefresh(hostID: host.id, now: now))
            model.finishRefresh(hostID: host.id, succeeded: true, now: now)
            #expect(!model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(59)))
            #expect(model.beginRefresh(hostID: host.id, now: now.addingTimeInterval(60)))
        }
    }

    @Test func menuAndFreshnessUseOnlySelectedHost() async throws {
        try await withModel { model, _ in
            let alpha = SSHHost(alias: "alpha", controlPath: "/tmp/alpha")
            let beta = SSHHost(alias: "beta", controlPath: "/tmp/beta")
            model.hosts = [alpha, beta]
            for host in model.hosts {
                model.snapshots[host.id] = ClusterSnapshot(partitions: [PartitionSnapshot(name: "cpu", nodes: [
                    SlurmNode(name: "node", state: "idle", allocatedCPUs: 0, totalCPUs: 64)
                ])], jobs: [])
                model.statuses[host.id] = "Connected"
            }
            model.selectedAlias = "alpha"
            model.activeHosts = [alpha.id, beta.id]
            #expect(model.menuTitle == "Slurm 1 idle")
            #expect(!model.isSnapshotCurrent(beta.id))
            model.hosts[0].enabled = false
            #expect(model.menuTitle == "Slurm")
            #expect(!model.isSnapshotCurrent(alpha.id))
        }
    }
}
