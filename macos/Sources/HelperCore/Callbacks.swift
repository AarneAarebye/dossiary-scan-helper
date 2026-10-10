import Foundation

public struct CallbackTimeout: LocalizedError, CustomStringConvertible {
    public var description: String { "The scanner didn't answer in time." }
    public var errorDescription: String? { description }
}

/// Resumes a continuation at most once: the first of a delegate callback and a timeout wins.
public final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    public func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// Bridges a callback-style request to async. `start` gets the Once to resume; `timeout` nil waits forever.
public func awaitCallback<T: Sendable>(timeout: TimeInterval?, _ start: (Once<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let once = Once(continuation)
        if let timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(.failure(CallbackTimeout())) }
        }
        start(once)
    }
}
