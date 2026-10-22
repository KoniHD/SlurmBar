import Observation

/// Give cancellation a short grace period without waiting indefinitely for filesystem work.
@MainActor
@Observable
final class QuitCoordinator {
    private(set) var isQuitting = false
    @ObservationIgnored private var didTerminate = false
    @ObservationIgnored private var deadline: Task<Void, Never>?

    func quit(grace: Duration = .seconds(2),
              hideUI: () -> Void,
              stopMonitoring: @escaping @MainActor () async -> Void,
              terminate: @escaping @MainActor () -> Void) {
        guard !isQuitting else { return }
        isQuitting = true
        hideUI()
        deadline = Task {
            do { try await Task.sleep(for: grace) }
            catch { return }
            finish(terminate: terminate)
        }
        // A task group would wait for non-cancellable work before returning,
        // defeating the shutdown deadline. Keep the cleanup task independent.
        Task {
            await stopMonitoring()
            finish(terminate: terminate)
        }
    }

    private func finish(terminate: () -> Void) {
        guard !didTerminate else { return }
        didTerminate = true
        deadline?.cancel()
        deadline = nil
        terminate()
    }
}
