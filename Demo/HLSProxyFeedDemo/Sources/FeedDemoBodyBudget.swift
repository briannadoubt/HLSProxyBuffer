import Foundation

/// Admission precedes file reads. Permits survive route throttling and are
/// released only when HTTPResponse's transport lifetime ends.
actor FeedDemoBodyBudget {
    struct Snapshot: Codable, Equatable, Sendable {
        var activeBodyCount = 0
        var activeBodyBytes = 0
        var maximumBodyCount = 0
        var maximumBodyBytes = 0
        var materializationCount = 0
        var cancellationCount = 0
        var queuedCount = 0
    }

    final class Permit: Sendable {
        let bytes: Int
        let budget: FeedDemoBodyBudget
        init(bytes: Int, budget: FeedDemoBodyBudget) {
            self.bytes = bytes
            self.budget = budget
        }
        deinit {
            let bytes = bytes, budget = budget
            Task { await budget.release(bytes: bytes) }
        }
    }

    private struct Waiter {
        let id: UUID
        let bytes: Int
        let continuation: CheckedContinuation<Permit, Error>
    }

    private let bodyLimit: Int
    private let byteLimit: Int
    private let queueLimit: Int
    private var state = Snapshot()
    private var waiters: [Waiter] = []

    init(bodyLimit: Int, byteLimit: Int, queueLimit: Int = 64) {
        self.bodyLimit = max(1, bodyLimit)
        self.byteLimit = max(1, byteLimit)
        self.queueLimit = max(1, queueLimit)
    }

    func acquire(bytes: Int) async throws -> Permit {
        guard (1...byteLimit).contains(bytes) else { throw URLError(.dataLengthExceedsMaximum) }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if state.activeBodyCount < bodyLimit { return admit(bytes: bytes) }
            guard waiters.count < queueLimit else { throw URLError(.resourceUnavailable) }
            return try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, bytes: bytes, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func snapshot() -> Snapshot {
        var value = state
        value.queuedCount = waiters.count
        return value
    }

    func resetAccounting() {
        state.maximumBodyCount = state.activeBodyCount
        state.maximumBodyBytes = state.activeBodyBytes
        state.materializationCount = 0
        state.cancellationCount = 0
    }

    func didMaterialize() { state.materializationCount += 1 }

    private func admit(bytes: Int) -> Permit {
        state.activeBodyCount += 1
        state.activeBodyBytes += bytes
        state.maximumBodyCount = max(state.maximumBodyCount, state.activeBodyCount)
        state.maximumBodyBytes = max(state.maximumBodyBytes, state.activeBodyBytes)
        return Permit(bytes: bytes, budget: self)
    }

    private func release(bytes: Int) {
        state.activeBodyCount -= 1
        state.activeBodyBytes -= bytes
        guard !waiters.isEmpty else { return }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: admit(bytes: waiter.bytes))
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        state.cancellationCount += 1
        waiter.continuation.resume(throwing: CancellationError())
    }
}
