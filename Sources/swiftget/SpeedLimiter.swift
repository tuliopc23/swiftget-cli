import Foundation

final class SpeedLimiter {
    private let maxBytesPerSecond: Int
    private var windowStart: Date
    private var bytesInWindow: Int

    init(maxBytesPerSecond: Int) {
        self.maxBytesPerSecond = maxBytesPerSecond
        self.windowStart = Date()
        self.bytesInWindow = 0
    }

    func throttle(wrote bytes: Int) async {
        bytesInWindow += bytes
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed < 1.0 && bytesInWindow > maxBytesPerSecond {
            let sleepTime = 1.0 - elapsed
            if sleepTime > 0 {
                let ns = UInt64(sleepTime * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
            windowStart = Date()
            bytesInWindow = 0
        } else if elapsed >= 1.0 {
            windowStart = Date()
            bytesInWindow = 0
        }
    }
}