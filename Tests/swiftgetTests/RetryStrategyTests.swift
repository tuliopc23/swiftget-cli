import XCTest
import Foundation
import Logging
@testable import swiftget

final class RetryStrategyTests: XCTestCase {
    
    var logger: Logger!
    var retryStrategy: RetryStrategy!
    
    override func setUp() async throws {
        try await super.setUp()
        logger = Logger(label: "test-retry-strategy")
        logger.logLevel = .error // Reduce noise in tests
    }
    
    // MARK: - BackoffType Tests
    
    func testExponentialBackoff() {
        let backoff = BackoffType.exponential(base: 1.0, multiplier: 2.0, maxDelay: 60.0)
        
        // Test exponential growth
        XCTAssertEqual(backoff.calculateDelay(for: 1), 1.0, accuracy: 0.01)
        XCTAssertEqual(backoff.calculateDelay(for: 2), 2.0, accuracy: 0.01)
        XCTAssertEqual(backoff.calculateDelay(for: 3), 4.0, accuracy: 0.01)
        XCTAssertEqual(backoff.calculateDelay(for: 4), 8.0, accuracy: 0.01)
        
        // Test max delay capping
        XCTAssertEqual(backoff.calculateDelay(for: 10), 60.0, accuracy: 0.01)
    }
    
    func testLinearBackoff() {
        let backoff = BackoffType.linear(increment: 2.0, maxDelay: 10.0)
        
        // Test linear growth
        XCTAssertEqual(backoff.calculateDelay(for: 1, baseDelay: 1.0), 1.0, accuracy: 0.01)
        XCTAssertEqual(backoff.calculateDelay(for: 2, baseDelay: 1.0), 3.0, accuracy: 0.01)
        XCTAssertEqual(backoff.calculateDelay(for: 3, baseDelay: 1.0), 5.0, accuracy: 0.01)
        
        // Test max delay capping
        XCTAssertEqual(backoff.calculateDelay(for: 10, baseDelay: 1.0), 10.0, accuracy: 0.01)
    }
    
    func testFixedBackoff() {
        let backoff = BackoffType.fixed(delay: 5.0)
        
        // Test consistent delay
        for attempt in 1...10 {
            XCTAssertEqual(backoff.calculateDelay(for: attempt), 5.0, accuracy: 0.01)
        }
    }
    
    func testNoBackoff() {
        let backoff = BackoffType.none
        
        // Test no delay
        for attempt in 1...10 {
            XCTAssertEqual(backoff.calculateDelay(for: attempt), 0.0, accuracy: 0.01)
        }
    }
    
    // MARK: - JitterType Tests
    
    func testUniformJitter() {
        let jitter = JitterType.uniform(range: 0.5...1.5)
        let baseDelay: TimeInterval = 10.0
        
        // Test multiple applications to ensure randomness is within range
        for _ in 0..<100 {
            let jitteredDelay = jitter.applyJitter(to: baseDelay)
            XCTAssertGreaterThanOrEqual(jitteredDelay, baseDelay * 0.5)
            XCTAssertLessThanOrEqual(jitteredDelay, baseDelay * 1.5)
        }
    }
    
    func testGaussianJitter() {
        let jitter = JitterType.gaussian(standardDeviation: 0.1)
        let baseDelay: TimeInterval = 10.0
        
        // Test multiple applications - most should be close to base delay
        var delays: [TimeInterval] = []
        for _ in 0..<100 {
            let jitteredDelay = jitter.applyJitter(to: baseDelay)
            XCTAssertGreaterThanOrEqual(jitteredDelay, 0.0) // Should never be negative
            delays.append(jitteredDelay)
        }
        
        // Check that average is close to base delay
        let average = delays.reduce(0, +) / Double(delays.count)
        XCTAssertEqual(average, baseDelay, accuracy: 1.0) // Within 1 second of base
    }
    
    func testDecorrelatedJitter() {
        let previousDelay: TimeInterval = 5.0
        let jitter = JitterType.decorrelated
        let baseDelay: TimeInterval = 10.0
        
        // Test multiple applications
        for _ in 0..<100 {
            let jitteredDelay = jitter.applyJitter(to: baseDelay, previousDelay: previousDelay)
            XCTAssertGreaterThanOrEqual(jitteredDelay, 0.0)
            XCTAssertLessThanOrEqual(jitteredDelay, max(baseDelay, previousDelay * 3))
        }
    }
    
    func testNoJitter() {
        let jitter = JitterType.none
        let baseDelay: TimeInterval = 10.0
        
        // Test that no jitter is applied
        XCTAssertEqual(jitter.applyJitter(to: baseDelay), baseDelay)
    }
    
    // MARK: - RetryConfiguration Tests
    
    func testPredefinedConfigurations() {
        // Test immediate configuration
        let immediate = RetryConfiguration.immediate
        XCTAssertEqual(immediate.maxAttempts, 3)
        XCTAssertEqual(immediate.baseDelay, 1.0)
        
        // Test conservative configuration
        let conservative = RetryConfiguration.conservative
        XCTAssertEqual(conservative.maxAttempts, 3)
        XCTAssertEqual(conservative.baseDelay, 2.0)
        
        // Test aggressive configuration
        let aggressive = RetryConfiguration.aggressive
        XCTAssertEqual(aggressive.maxAttempts, 7)
        XCTAssertEqual(aggressive.baseDelay, 0.5)
        
        // Test linear backoff configuration
        let linear = RetryConfiguration.linearBackoff
        XCTAssertEqual(linear.maxAttempts, 5)
        
        // Test fixed delay configuration
        let fixed = RetryConfiguration.fixedDelay
        XCTAssertEqual(fixed.maxAttempts, 5)
    }
    
    // MARK: - RetryStrategy Tests
    
    func testRetryStrategyInitialization() {
        let config = RetryConfiguration.conservative
        retryStrategy = RetryStrategy(configuration: config, logger: logger)
        
        // Test that strategy is properly initialized
        XCTAssertNotNil(retryStrategy)
    }
    
    func testShouldRetryWithRetryableError() {
        let config = RetryConfiguration(
            maxAttempts: 3,
            retryableErrors: ["TestError"]
        )
        retryStrategy = RetryStrategy(configuration: config, logger: logger)
        
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "TestError" }
        }
        
        let error = TestError()
        let decision = retryStrategy.shouldRetry(error: error)
        
        switch decision {
        case .retry(let delay):
            XCTAssertGreaterThanOrEqual(delay, 0.0)
        case .stop, .circuitBreakerOpen:
            XCTFail("Should have decided to retry")
        }
    }
    
    func testShouldStopAfterMaxAttempts() {
        let config = RetryConfiguration(
            maxAttempts: 2,
            retryableErrors: ["TestError"]
        )
        retryStrategy = RetryStrategy(configuration: config, logger: logger)
        
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "TestError" }
        }
        
        let error = TestError()
        
        // First attempt should retry
        var decision = retryStrategy.shouldRetry(error: error)
        switch decision {
        case .retry:
            break // Expected
        case .stop, .circuitBreakerOpen:
            XCTFail("First retry should be allowed")
        }
        
        // Second attempt should retry
        decision = retryStrategy.shouldRetry(error: error)
        switch decision {
        case .retry:
            break // Expected
        case .stop, .circuitBreakerOpen:
            XCTFail("Second retry should be allowed")
        }
        
        // Third attempt should stop (exceeded maxAttempts)
        decision = retryStrategy.shouldRetry(error: error)
        switch decision {
        case .stop:
            break // Expected
        case .retry, .circuitBreakerOpen:
            XCTFail("Should have stopped after max attempts")
        }
    }
    
    func testCircuitBreakerBehavior() {
        let config = RetryConfiguration(
            maxAttempts: 10,
            enableCircuitBreaker: true,
            circuitBreakerThreshold: 3
        )
        retryStrategy = RetryStrategy(configuration: config, logger: logger)
        
        struct TestError: Error {}
        let error = TestError()
        
        // First few failures should trigger retries
        for _ in 1...2 {
            let decision = retryStrategy.shouldRetry(error: error)
            switch decision {
            case .retry:
                break // Expected
            default:
                XCTFail("Should retry before circuit breaker threshold")
            }
        }
        
        // After threshold, circuit breaker should open
        let decision = retryStrategy.shouldRetry(error: error)
        switch decision {
        case .circuitBreakerOpen:
            break // Expected
        default:
            XCTFail("Circuit breaker should be open after threshold")
        }
    }
    
    func testMaxTotalTimeLimit() async {
        let config = RetryConfiguration(
            maxAttempts: 10,
            backoffType: .fixed(delay: 2.0),
            maxTotalTime: 3.0 // 3 seconds total
        )
        retryStrategy = RetryStrategy(configuration: config, logger: logger)
        
        struct TestError: Error {}
        let error = TestError()
        
        let startTime = Date()
        
        // Keep retrying until time limit is reached
        var attempts = 0
        while attempts < config.maxAttempts {
            let decision = retryStrategy.shouldRetry(error: error)
            
            switch decision {
            case .retry(let delay):
                attempts += 1
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            case .stop:
                // Should stop due to time limit
                let elapsed = Date().timeIntervalSince(startTime)
                XCTAssertGreaterThanOrEqual(elapsed, config.maxTotalTime! - 1.0) // Allow some tolerance
                return
            case .circuitBreakerOpen:
                XCTFail("Circuit breaker should not be enabled in this test")
                return
            }
        }
        
        XCTFail("Should have stopped due to time limit")
    }
    
    // MARK: - BackoffCalculator Tests
    
    func testBackoffCalculatorBasicOperations() {
        var calculator = BackoffCalculator(configuration: .conservative)
        
        // Test delay calculation
        let delay1 = calculator.calculateDelay(for: 1)
        let delay2 = calculator.calculateDelay(for: 2)
        let delay3 = calculator.calculateDelay(for: 3)
        
        XCTAssertGreaterThan(delay2, delay1)
        XCTAssertGreaterThan(delay3, delay2)
        XCTAssertGreaterThanOrEqual(delay1, 0.0)
    }
    
    func testBackoffCalculatorWithFibonacci() {
        let config = BackoffCalculator.Configuration.fibonacci
        var calculator = BackoffCalculator(configuration: config)
        
        let delays = (1...5).map { calculator.calculateDelay(for: $0) }
        
        // Fibonacci sequence should show characteristic growth pattern
        XCTAssertTrue(delays.allSatisfy { $0 > 0 })
        XCTAssertLessThanOrEqual(delays.max() ?? 0, config.maxDelay)
    }
    
    func testBackoffCalculatorBatchOperations() {
        var calculator = BackoffCalculator(configuration: .linear)
        
        let attempts = [1, 2, 3, 4, 5]
        let delays = calculator.calculateDelays(for: attempts)
        
        XCTAssertEqual(delays.count, attempts.count)
        XCTAssertTrue(delays.allSatisfy { $0 >= 0 })
    }
    
    func testBackoffCalculatorTotalTime() {
        let calculator = BackoffCalculator(configuration: .conservative)
        
        let totalTime = calculator.calculateTotalTime(for: 5)
        XCTAssertGreaterThan(totalTime, 0.0)
    }
    
    func testBackoffCalculatorDelaySequence() {
        var calculator = BackoffCalculator(configuration: .aggressive)
        
        let sequence = calculator.generateDelaySequence(maxTime: 10.0)
        
        XCTAssertFalse(sequence.isEmpty)
        XCTAssertLessThanOrEqual(sequence.reduce(0, +), 10.0)
    }
    
    func testPrebuiltBackoffCalculators() {
        // Test network operations calculator
        var networkCalc = BackoffCalculator.forNetworkOperations()
        let networkDelay = networkCalc.calculateDelay(for: 1)
        XCTAssertGreaterThanOrEqual(networkDelay, 0.0)
        
        // Test rate limiting calculator
        var rateLimitCalc = BackoffCalculator.forRateLimiting()
        let rateLimitDelay = rateLimitCalc.calculateDelay(for: 1)
        XCTAssertGreaterThanOrEqual(rateLimitDelay, 0.0)
        
        // Test API client calculator
        var apiCalc = BackoffCalculator.forAPIClient()
        let apiDelay = apiCalc.calculateDelay(for: 1)
        XCTAssertGreaterThanOrEqual(apiDelay, 0.0)
        
        // Test download retries calculator
        var downloadCalc = BackoffCalculator.forDownloadRetries()
        let downloadDelay = downloadCalc.calculateDelay(for: 1)
        XCTAssertGreaterThanOrEqual(downloadDelay, 0.0)
    }
    
    // MARK: - Integration Tests
    
    func testRetryStrategyWithBackoffCalculator() {
        let retryConfig = RetryConfiguration.aggressive
        let backoffConfig = BackoffCalculator.Configuration.aggressive
        
        let strategy = RetryStrategy(configuration: retryConfig, logger: logger)
        var calculator = BackoffCalculator(configuration: backoffConfig)
        
        struct TestError: Error {}
        let error = TestError()
        
        // Test that both work together
        let retryDecision = strategy.shouldRetry(error: error)
        let backoffDelay = calculator.calculateDelay(for: 1)
        
        switch retryDecision {
        case .retry(let retryDelay):
            XCTAssertGreaterThanOrEqual(retryDelay, 0.0)
            XCTAssertGreaterThanOrEqual(backoffDelay, 0.0)
        case .stop, .circuitBreakerOpen:
            // Could happen depending on error classification
            break
        }
    }
    
    // MARK: - Performance Tests
    
    func testRetryStrategyPerformance() {
        let config = RetryConfiguration.conservative
        let strategy = RetryStrategy(configuration: config, logger: logger)
        
        struct TestError: Error {}
        let error = TestError()
        
        measure {
            for _ in 0..<1000 {
                _ = strategy.shouldRetry(error: error)
            }
        }
    }
    
    func testBackoffCalculatorPerformance() {
        var calculator = BackoffCalculator(configuration: .conservative)
        
        measure {
            for attempt in 1...1000 {
                _ = calculator.calculateDelay(for: attempt)
            }
        }
    }
    
    // MARK: - Edge Cases
    
    func testZeroAttempts() {
        var calculator = BackoffCalculator(configuration: .conservative)
        let delay = calculator.calculateDelay(for: 0)
        XCTAssertEqual(delay, 0.0)
    }
    
    func testNegativeAttempts() {
        var calculator = BackoffCalculator(configuration: .conservative)
        let delay = calculator.calculateDelay(for: -5)
        XCTAssertGreaterThanOrEqual(delay, 0.0)
    }
    
    func testVeryLargeAttempts() {
        var calculator = BackoffCalculator(configuration: .conservative)
        let delay = calculator.calculateDelay(for: 1000000)
        // Should be bounded by maxDelay (we can't access private configuration, so just check it's reasonable)
        XCTAssertLessThanOrEqual(delay, 300.0) // Reasonable upper bound
    }
    
    func testMinDelayConstraints() {
        let config = BackoffCalculator.Configuration(
            algorithm: .fixed(delay: 0.01),
            jitter: .none,
            minDelay: 1.0,
            maxDelay: 10.0
        )
        var calculator = BackoffCalculator(configuration: config)
        
        let delay = calculator.calculateDelay(for: 1)
        XCTAssertGreaterThanOrEqual(delay, config.minDelay)
    }
    
    func testMaxDelayConstraints() {
        let config = BackoffCalculator.Configuration(
            algorithm: .exponential(base: 10.0, multiplier: 10.0, maxDelay: 1000.0),
            jitter: .none,
            minDelay: 0.1,
            maxDelay: 5.0 // Lower than algorithm max
        )
        var calculator = BackoffCalculator(configuration: config)
        
        let delay = calculator.calculateDelay(for: 10) // Should hit max
        XCTAssertLessThanOrEqual(delay, config.maxDelay)
    }
}