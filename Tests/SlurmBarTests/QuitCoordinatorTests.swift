import Testing
@testable import SlurmBar

@MainActor
struct QuitCoordinatorTests {
    @Test func completedCleanupQuitsWithoutWaitingForDeadline() async {
        let coordinator = QuitCoordinator()
        let terminated = AsyncStream<Void>.makeStream()
        var stops = 0
        var terminations = 0
        var hidden = false
        coordinator.quit(grace: .seconds(60), hideUI: { hidden = true }, stopMonitoring: {
            #expect(hidden)
            stops += 1
        }) {
            terminations += 1
            terminated.continuation.yield(())
        }
        #expect(coordinator.isQuitting)
        #expect(hidden)
        #expect(stops == 0)
        coordinator.quit(hideUI: { Issue.record("Repeated Quit must not hide UI again") },
                         stopMonitoring: { Issue.record("Repeated Quit must not restart cleanup") }) {
            Issue.record("Repeated Quit must not terminate twice")
        }
        for await _ in terminated.stream { break }
        #expect(stops == 1)
        #expect(terminations == 1)
    }

    @Test func stalledMonitoringCannotDelayQuitAndLateCompletionDoesNotQuitTwice() async throws {
        let coordinator = QuitCoordinator()
        let release = AsyncStream<Void>.makeStream()
        let stopped = AsyncStream<Void>.makeStream()
        let terminated = AsyncStream<Void>.makeStream()
        var didStop = false
        var terminations = 0
        var hidden = false
        coordinator.quit(grace: .milliseconds(20), hideUI: { hidden = true }, stopMonitoring: {
            for await _ in release.stream { break }
            didStop = true
            stopped.continuation.yield(())
        }) {
            terminations += 1
            terminated.continuation.yield(())
        }
        #expect(hidden)
        #expect(!didStop)
        for await _ in terminated.stream { break }
        #expect(!didStop)
        #expect(terminations == 1)
        release.continuation.yield(())
        for await _ in stopped.stream { break }
        // Let the cleanup task return to the coordinator after signalling completion.
        await Task.yield()
        #expect(didStop)
        #expect(terminations == 1)
    }
}
