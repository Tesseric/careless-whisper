import Foundation
import os

/// Thread-safe accumulator for audio samples.
/// Uses os_unfair_lock because the AVAudioEngine tap callback runs on a real-time audio thread.
final class AudioBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private var lock = os_unfair_lock()

    func append(_ newSamples: [Float]) {
        os_unfair_lock_lock(&lock)
        samples.append(contentsOf: newSamples)
        os_unfair_lock_unlock(&lock)
    }

    func flush() -> [Float] {
        os_unfair_lock_lock(&lock)
        let result = samples
        samples.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(&lock)
        return result
    }

    var count: Int {
        os_unfair_lock_lock(&lock)
        let c = samples.count
        os_unfair_lock_unlock(&lock)
        return c
    }
}
