import Foundation

/// Caps the number of concurrent awaits (image downloads / decodes).
/// Back-deployed to iOS 13, so it is safe on the iOS 14.5 minimum target.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
