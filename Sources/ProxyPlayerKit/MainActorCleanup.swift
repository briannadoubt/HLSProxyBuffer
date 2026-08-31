import Foundation

/// Keeps resource teardown on the main actor without the isolated-deinit runtime
/// thunk, which can invalid-free task-local storage on older supported OSes.
/// Capture a separate resource owner, never the object whose deinit is running.
func performMainActorCleanup(_ cleanup: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { cleanup() }
    } else {
        DispatchQueue.main.async(execute: cleanup)
    }
}
