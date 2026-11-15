import Foundation

// What differs between Apple platforms and Linux, in one place.

#if canImport(os)
import os

/// A lock around a value: os_unfair_lock where there is one.
public typealias StateLock<State> = OSAllocatedUnfairLock<State>
#else
/// A lock around a value: os_unfair_lock where there is one.
public final class StateLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    public init(initialState: State) {
        state = initialState
    }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    /// Nil, without waiting, when another thread holds the lock: for audio threads.
    public func withLockIfAvailable<R>(_ body: (inout State) throws -> R) rethrows -> R? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return try body(&state)
    }
}
#endif
