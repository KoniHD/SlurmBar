import Foundation
import Testing
import SlurmBarCore
@testable import SlurmBar

@MainActor
struct UpdateControllerTests {
    private static let release = UpdateRelease(
        version: SemanticVersion(0, 3, 0),
        notesURL: URL(string: "https://github.com/KoniHD/SlurmBar/releases/tag/v0.3.0")!,
        diskImageURL: URL(string: "https://github.com/KoniHD/SlurmBar/releases/download/v0.3.0/SlurmBar.dmg")!,
        signatureURL: URL(string: "https://github.com/KoniHD/SlurmBar/releases/download/v0.3.0/SlurmBar.dmg.sig")!)

    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "SlurmBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    private func controller(_ defaults: UserDefaults,
                            appURL: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SlurmBar.app"),
                            check: @escaping @Sendable (SemanticVersion) async throws -> UpdateRelease? = { _ in release },
                            stage: @escaping @Sendable (UpdateRelease, URL) async throws -> StagedUpdate = { _, url in
                                StagedUpdate(stagingDirectory: url, stagedApp: url, destination: url) },
                            relaunch: @escaping @MainActor (StagedUpdate) throws -> Void = { _ in }) -> UpdateController {
        UpdateController(defaults: defaults, currentVersion: SemanticVersion(0, 2, 0), appURL: appURL,
                         startChecking: false, check: check, stage: stage, relaunch: relaunch)
    }

    @Test func checkPublishesAvailableReleaseAndRecordsTime() async throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let updater = controller(defaults)
        #expect(updater.isAutomaticCheckDue)
        await updater.checkNow()
        #expect(updater.availableRelease == Self.release)
        #expect(!updater.isChecking)
        #expect(!updater.isAutomaticCheckDue)
        #expect(defaults.double(forKey: UpdateController.lastCheckKey) > 0)
    }

    @Test func upToDateClearsReleaseAndFailureKeepsIt() async throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let box = ResultBox()
        let updater = controller(defaults, check: { _ in try await box.next() })
        await box.set(.success(Self.release)); await updater.checkNow()
        #expect(updater.availableRelease != nil)
        await box.set(.failure(UpdateError.timedOut)); await updater.checkNow()
        #expect(updater.availableRelease != nil)
        #expect(updater.message?.hasPrefix("Update check failed") == true)
        await box.set(.success(nil)); await updater.checkNow()
        #expect(updater.availableRelease == nil)
        #expect(updater.message == "SlurmBar is up to date.")
    }

    @Test func failedCheckIsRetriedSoonerThanADay() async throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let updater = controller(defaults, check: { _ in throw UpdateError.timedOut })
        await updater.checkNow()
        #expect(updater.isAutomaticCheckDue)
    }

    @Test func installStagesThenRelaunchesOnce() async throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let log = Log()
        let updater = controller(defaults, relaunch: { staged in log.append(staged.destination.lastPathComponent) })
        await updater.checkNow()
        await updater.installAvailableUpdate()
        #expect(log.items == ["SlurmBar.app"])
        #expect(!updater.isInstalling)
    }

    @Test func installFailureReportsMessageAndDoesNotRelaunch() async throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let log = Log()
        let updater = controller(defaults, stage: { _, _ in throw UpdateError.badSignature },
                                 relaunch: { _ in log.append("relaunch") })
        await updater.checkNow()
        await updater.installAvailableUpdate()
        #expect(log.items.isEmpty)
        #expect(updater.message == UpdateError.badSignature.errorDescription)
        #expect(updater.availableRelease != nil)
    }

    @Test func readOnlyOrNonBundleLocationCannotInstall() async throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let log = Log()
        let updater = controller(defaults, appURL: URL(fileURLWithPath: "/usr/bin/SlurmBar"),
                                 stage: { _, _ in Issue.record("must not stage"); throw UpdateError.timedOut },
                                 relaunch: { _ in log.append("relaunch") })
        #expect(!updater.canInstall)
        await updater.checkNow()
        await updater.installAvailableUpdate()
        #expect(log.items.isEmpty)
    }

    @Test func automaticChecksDefaultOnAndPersistWhenDisabled() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let updater = controller(defaults)
        #expect(updater.automaticChecks)
        updater.automaticChecks = false
        #expect(!controller(defaults).automaticChecks)
    }

    @Test func unversionedBuildDoesNotCheck() async throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let updater = UpdateController(defaults: defaults, currentVersion: nil, startChecking: false,
                                       check: { _ in Issue.record("must not check"); return nil })
        await updater.checkNow()
        #expect(updater.availableRelease == nil)
    }

    /// Regression: `terminate(_:)` with `.terminateLater` spins a nested run loop until main-actor
    /// tasks reply. Started directly from a main-actor job, those tasks never ran and the update hung.
    /// The test process has no AppKit modal mode, so the nested loop runs in the default mode.
    @Test func runLoopWorkCanWaitForMainActorTasks() async {
        let replied = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            UpdateController.performFromRunLoop {
                var didReply = false
                Task { @MainActor in didReply = true }
                let deadline = Date().addingTimeInterval(3)
                while !didReply, Date() < deadline {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                continuation.resume(returning: didReply)
            }
        }
        #expect(replied)
    }
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ item: String) { lock.lock(); storage.append(item); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private actor ResultBox {
    private var result: Result<UpdateRelease?, Error> = .success(nil)
    func set(_ value: Result<UpdateRelease?, Error>) { result = value }
    func next() throws -> UpdateRelease? { try result.get() }
}
