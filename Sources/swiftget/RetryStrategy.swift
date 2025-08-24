import Foundation
import Logging

/// Different types of backoff strategies for retry logic
enum BackoffType {
    case exponential(base: TimeInterval, multiplier: Double, maxDelay: TimeInterval)
    case linear(increment: TimeInterval, maxDelay: TimeInterval)
    case fixed(delay: TimeInterval)
    case none
    
    /// Calculate the delay for a given attempt number
    func calculateDelay(for attempt: Int, baseDelay: TimeInterval = 1.0) -> TimeInterval {
        switch self {
        case .exponential(let base, let multiplier, let maxDelay):
            let delay = base * pow(multiplier, Double(attempt - 1))
            return min(delay, maxDelay)
            
        case .linear(let increment, let maxDelay):
            let delay = baseDelay + (increment * Double(attempt - 1))
            return min(delay, maxDelay)
            
        case .fixed(let delay):
            return delay
            
        case .none:
            return 0
        }
    }
}

/// Jitter strategies to prevent thundering herd problem
enum JitterType {
    case none
    case uniform(range: ClosedRange<Double>) // Random factor between range
    case gaussian(standardDeviation: Double) // Gaussian distribution
    case decorrelated // Decorrelated jitter algorithm
    
    /// Apply jitter to a delay value
    func applyJitter(to delay: TimeInterval, previousDelay: TimeInterval = 0) -> TimeInterval {
        switch self {
        case .none:
            return delay
            
        case .uniform(let range):
            let factor = Double.random(in: range)
            return delay * factor
            
        case .gaussian(let stdDev):
            let gaussian = gaussianRandom(mean: 1.0, standardDeviation: stdDev)
            return max(0, delay * gaussian)
            
        case .decorrelated:
            // Decorrelated jitter: random between 0 and previous_delay * 3
            let maxJitter = max(delay, previousDelay * 3)
            return Double.random(in: 0...maxJitter)
        }
    }
    
    private func gaussianRandom(mean: Double, standardDeviation: Double) -> Double {
        // Box-Muller transform for generating Gaussian random numbers
        let u1 = Double.random(in: 0.001...0.999) // Avoid exact 0 for log
        let u2 = Double.random(in: 0...1)
        
        let z0 = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        return mean + z0 * standardDeviation
    }
}

/// Configuration for retry behavior
struct RetryConfiguration {
    let maxAttempts: Int
    let backoffType: BackoffType
    let jitterType: JitterType
    let baseDelay: TimeInterval
    let maxTotalTime: TimeInterval? // Maximum total time to spend retrying
    let retryableErrors: Set<String> // Error types that should trigger retry
    let enableCircuitBreaker: Bool
    let circuitBreakerThreshold: Int // Number of failures to open circuit
    
    init(
        maxAttempts: Int = 3,
        backoffType: BackoffType = .exponential(base: 1.0, multiplier: 2.0, maxDelay: 60.0),
        jitterType: JitterType = .uniform(range: 0.5...1.5),
        baseDelay: TimeInterval = 1.0,
        maxTotalTime: TimeInterval? = nil,
        retryableErrors: Set<String> = [],
        enableCircuitBreaker: Bool = false,
        circuitBreakerThreshold: Int = 5
    ) {
        self.maxAttempts = maxAttempts
        self.backoffType = backoffType
        self.jitterType = jitterType
        self.baseDelay = baseDelay
        self.maxTotalTime = maxTotalTime
        self.retryableErrors = retryableErrors
        self.enableCircuitBreaker = enableCircuitBreaker
        self.circuitBreakerThreshold = circuitBreakerThreshold
    }
    
    /// Predefined configurations for common scenarios
    static let immediate = RetryConfiguration(
        maxAttempts: 3,
        backoffType: .none,
        jitterType: .none
    )
    
    static let conservative = RetryConfiguration(
        maxAttempts: 3,
        backoffType: .exponential(base: 2.0, multiplier: 2.0, maxDelay: 30.0),
        jitterType: .uniform(range: 0.8...1.2),
        baseDelay: 2.0
    )
    
    static let aggressive = RetryConfiguration(
        maxAttempts: 7,
        backoffType: .exponential(base: 0.5, multiplier: 1.5, maxDelay: 60.0),
        jitterType: .decorrelated,
        baseDelay: 0.5
    )
    
    static let linearBackoff = RetryConfiguration(
        maxAttempts: 5,
        backoffType: .linear(increment: 2.0, maxDelay: 30.0),
        jitterType: .uniform(range: 0.9...1.1),
        baseDelay: 1.0
    )
    
    static let fixedDelay = RetryConfiguration(
        maxAttempts: 5,
        backoffType: .fixed(delay: 3.0),
        jitterType: .uniform(range: 0.5...1.5)
    )
}

/// State tracking for retry attempts
struct RetryState {
    let startTime: Date
    var attemptCount: Int = 0
    var lastDelay: TimeInterval = 0
    var totalElapsedTime: TimeInterval { Date().timeIntervalSince(startTime) }
    var circuitBreakerFailures: Int = 0
    var circuitBreakerOpen: Bool = false
    var lastCircuitBreakerTime: Date?
    
    init() {
        self.startTime = Date()
    }
    
    mutating func recordAttempt(delay: TimeInterval) {
        attemptCount += 1
        lastDelay = delay
    }
    
    mutating func recordFailure() {
        circuitBreakerFailures += 1
    }
    
    mutating func recordSuccess() {
        circuitBreakerFailures = 0
        circuitBreakerOpen = false
    }
    
    mutating func openCircuitBreaker() {
        circuitBreakerOpen = true
        lastCircuitBreakerTime = Date()
    }
    
    func shouldTryCircuitBreaker(resetTime: TimeInterval = 60.0) -> Bool {
        guard let lastTime = lastCircuitBreakerTime else { return false }
        return Date().timeIntervalSince(lastTime) >= resetTime
    }
}

/// Advanced retry strategy with configurable backoff, jitter, and circuit breaker
class RetryStrategy {
    let configuration: RetryConfiguration
    private let logger: Logger
    private var state = RetryState()
    
    init(configuration: RetryConfiguration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
    }
    
    /// Determine whether to retry after a failure
    func shouldRetry(error: Error) -> RetryDecision {
        // Check circuit breaker
        if configuration.enableCircuitBreaker && state.circuitBreakerOpen {
            if state.shouldTryCircuitBreaker() {
                logger.info("Circuit breaker attempting half-open state")
                // Allow one attempt to test if service has recovered
            } else {
                return .circuitBreakerOpen
            }
        }
        
        // Check if error is retryable
        if !isRetryableError(error) {
            return .stop(reason: "Error type not retryable: \(type(of: error))")
        }
        
        // Check max attempts
        if state.attemptCount >= configuration.maxAttempts {
            return .stop(reason: "Maximum attempts (\(configuration.maxAttempts)) reached")
        }
        
        // Check max total time
        if let maxTime = configuration.maxTotalTime,
           state.totalElapsedTime >= maxTime {
            return .stop(reason: "Maximum total time (\(maxTime)s) exceeded")
        }
        
        // Calculate delay with backoff and jitter
        let baseDelay = configuration.backoffType.calculateDelay(
            for: state.attemptCount + 1,
            baseDelay: configuration.baseDelay
        )
        
        let delayWithJitter = configuration.jitterType.applyJitter(
            to: baseDelay,
            previousDelay: state.lastDelay
        )
        
        // Record the attempt
        state.recordAttempt(delay: delayWithJitter)
        state.recordFailure()
        
        // Check circuit breaker threshold
        if configuration.enableCircuitBreaker &&
           state.circuitBreakerFailures >= configuration.circuitBreakerThreshold {
            state.openCircuitBreaker()
            logger.warning("Circuit breaker opened after \(state.circuitBreakerFailures) failures")
            return .circuitBreakerOpen
        }
        
        logger.debug("Retry attempt \(state.attemptCount) scheduled in \(String(format: "%.2f", delayWithJitter))s")
        
        return .retry(after: delayWithJitter)
    }
    
    /// Record a successful operation (resets circuit breaker)
    func recordSuccess() {
        state.recordSuccess()
        logger.debug("Operation succeeded, circuit breaker reset")
    }
    
    /// Reset the retry state for a new operation
    func reset() {
        state = RetryState()
    }
    
    /// Get current retry statistics
    func getStatistics() -> RetryStatistics {
        return RetryStatistics(
            attemptCount: state.attemptCount,
            totalElapsedTime: state.totalElapsedTime,
            lastDelay: state.lastDelay,
            circuitBreakerOpen: state.circuitBreakerOpen,
            circuitBreakerFailures: state.circuitBreakerFailures
        )
    }
    
    // MARK: - Private Methods
    
    private func isRetryableError(_ error: Error) -> Bool {
        // If no specific retryable errors are configured, retry all errors
        if configuration.retryableErrors.isEmpty {
            return true
        }
        
        // Check if error type is in retryable set
        let errorTypeName = String(describing: type(of: error))
        return configuration.retryableErrors.contains(errorTypeName)
    }
}

/// Statistics about retry attempts
struct RetryStatistics {
    let attemptCount: Int
    let totalElapsedTime: TimeInterval
    let lastDelay: TimeInterval
    let circuitBreakerOpen: Bool
    let circuitBreakerFailures: Int
    
    var averageDelayPerAttempt: TimeInterval {
        return attemptCount > 0 ? totalElapsedTime / Double(attemptCount) : 0
    }
    
    var successRate: Double {
        return attemptCount > 0 ? 1.0 / Double(attemptCount) : 0.0
    }
}

/// Convenience extensions for common retry patterns
extension RetryStrategy {
    
    /// Execute a block with retry logic
    func executeWithRetry<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        reset()
        
        while true {
            do {
                let result = try await operation()
                recordSuccess()
                return result
            } catch {
                let decision = shouldRetry(error: error)
                
                switch decision {
                case .retry(let delay):
                    logger.info("Retrying operation in \(String(format: "%.2f", delay))s due to: \(error)")
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    continue
                    
                case .stop(let reason):
                    logger.error("Stopping retries: \(reason)")
                    throw error
                    
                case .circuitBreakerOpen:
                    logger.error("Circuit breaker is open, not retrying")
                    throw RetryError.circuitBreakerOpen
                }
            }
        }
    }
    
    /// Execute with retry and custom error handling
    func executeWithRetry<T>(
        _ operation: @escaping () async throws -> T,
        errorHandler: @escaping (Error, Int) -> Void = { _, _ in }
    ) async throws -> T {
        reset()
        
        while true {
            do {
                let result = try await operation()
                recordSuccess()
                return result
            } catch {
                errorHandler(error, state.attemptCount)
                
                let decision = shouldRetry(error: error)
                
                switch decision {
                case .retry(let delay):
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    continue
                    
                case .stop:
                    throw error
                    
                case .circuitBreakerOpen:
                    throw RetryError.circuitBreakerOpen
                }
            }
        }
    }
}

/// Errors specific to retry operations
enum RetryError: Error, LocalizedError {
    case circuitBreakerOpen
    case maxAttemptsExceeded
    case maxTimeExceeded
    
    var errorDescription: String? {
        switch self {
        case .circuitBreakerOpen:
            return "Circuit breaker is open - service appears to be unavailable"
        case .maxAttemptsExceeded:
            return "Maximum retry attempts exceeded"
        case .maxTimeExceeded:
            return "Maximum retry time exceeded"
        }
    }
}