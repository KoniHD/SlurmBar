import AppKit
import Foundation
import Observation
import SlurmBarCore

/// Checks GitHub Releases for a newer signed build and installs it in place.
/// Unrelated to SSH monitoring: it only ever contacts github.com over HTTPS.
@MainActor
@Observable
final class UpdateController {
    private(set) var availableRelease: UpdateRelease?
    private(set) var isChecking = false
    private(set) var isInstalling = false
    private(set) var message: String?
    private(set) var lastChecked: Date?
    var automaticChecks: Bool {
        didSet {
            defaults.set(automaticChecks, forKey: Self.automaticKey)
            if automaticChecks { startLoop() } else { stopLoop() }
        }
    }

    let currentVersion: SemanticVersion?
    let appURL: URL
    var isBusy: Bool { isChecking || isInstalling }
    /// A source build or a copy in a read-only location can still check, but cannot replace itself.
    var canInstall: Bool {
        appURL.pathExtension == "app" && FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
    }

    static let automaticKey = "automaticUpdateChecks"
    static let lastCheckKey = "lastUpdateCheck"
    static let automaticInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let check: @Sendable (SemanticVersion) async throws -> UpdateRelease?
    private let stage: @Sendable (UpdateRelease, URL) async throws -> StagedUpdate
    private let relaunch: @MainActor (StagedUpdate) throws -> Void
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         currentVersion: SemanticVersion? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            .flatMap { ($0 as? String).flatMap(SemanticVersion.init) },
         appURL: URL = Bundle.main.bundleURL,
         bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.github.slurmbar.app",
         startChecking: Bool = true,
         check: (@Sendable (SemanticVersion) async throws -> UpdateRelease?)? = nil,
         stage: (@Sendable (UpdateRelease, URL) async throws -> StagedUpdate)? = nil,
         relaunch: @escaping @MainActor (StagedUpdate) throws -> Void = { staged in
             try UpdateInstaller.launchSwap(staged, waitingFor: ProcessInfo.processInfo.processIdentifier)
             UpdateController.performFromRunLoop { NSApplication.shared.terminate(nil) }
         }) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.appURL = appURL
        self.check = check ?? { try await UpdateChecker().check(current: $0) }
        let installer = UpdateInstaller(bundleIdentifier: bundleIdentifier)
        self.stage = stage ?? { try await installer.stage($0, replacing: $1) }
        self.relaunch = relaunch
        self.automaticChecks = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        let saved = defaults.double(forKey: Self.lastCheckKey)
        lastChecked = saved > 0 ? Date(timeIntervalSince1970: saved) : nil
        if startChecking, automaticChecks { startLoop() }
    }

    deinit { loop?.cancel() }

    /// Runs `work` from a main run loop callout instead of the current main-actor job.
    ///
    /// Main-actor jobs execute inside a main dispatch queue callout. `terminate(_:)` answered with
    /// `.terminateLater` spins a nested run loop that cannot drain the main queue from there, so the
    /// quit coordinator's main-actor tasks would never reply and the app would hang hidden while the
    /// swap helper gave up. A run loop block leaves the main queue free to run those tasks.
    static func performFromRunLoop(_ work: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { work() }
        }
    }

    private func startLoop() {
        guard loop == nil, currentVersion != nil else { return }
        loop = Task { [weak self] in
            // Let launch settle before touching the network.
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            while !Task.isCancelled {
                guard let self else { return }
                if self.isAutomaticCheckDue { await self.checkNow() }
                do { try await Task.sleep(for: .seconds(60 * 60)) } catch { return }
            }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
    }

    var isAutomaticCheckDue: Bool {
        guard let lastChecked else { return true }
        return Date().timeIntervalSince(lastChecked) >= Self.automaticInterval
    }

    func checkNow() async {
        guard !isBusy else { return }
        guard let currentVersion else {
            message = "Update checks are unavailable in builds without a version."
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try await check(currentVersion)
            availableRelease = release
            message = release == nil ? "SlurmBar is up to date." : nil
            recordCheck()
        } catch is CancellationError {
            return
        } catch {
            // A failed check is retried at the next interval; keep any known release visible.
            message = "Update check failed: \(error.localizedDescription)"
        }
    }

    func installAvailableUpdate() async {
        guard !isBusy, let release = availableRelease else { return }
        guard canInstall else {
            message = "SlurmBar can only update itself when installed as an app in a writable folder."
            return
        }
        isInstalling = true
        message = "Downloading SlurmBar \(release.version)…"
        defer { isInstalling = false }
        do {
            let staged = try await stage(release, appURL)
            message = "Restarting…"
            do { try relaunch(staged) }
            catch {
                try? FileManager.default.removeItem(at: staged.stagingDirectory)
                throw error
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func recordCheck() {
        let now = Date()
        lastChecked = now
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
    }
}
