import XCTest
@testable import swiftget

final class SpeedLimiterTests: XCTestCase {
    func testLimiterNoThrow() async throws {
        let limiter = SpeedLimiter(maxBytesPerSecond: 1024 * 1024) // 1MB/s
        for _ in 0..<10 {
            await limiter.throttle(wrote: 10_000)
        }
    }
}