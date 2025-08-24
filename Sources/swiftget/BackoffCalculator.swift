import Foundation

/// Standalone backoff calculator utility for retry mechanisms and rate limiting
/// Provides various backoff algorithms with jitter support to prevent thundering herd problems
struct BackoffCalculator {
    
    /// Backoff algorithm types
    enum Algorithm {
        case exponential(base: TimeInterval, multiplier: Double, maxDelay: TimeInterval)
        case linear(increment: TimeInterval, maxDelay: TimeInterval)
        case fixed(delay: TimeInterval)
        case fibonacci(maxDelay: TimeInterval)
        case polynomial(degree: Int, coefficient: TimeInterval, maxDelay: TimeInterval)
        
        /// Calculate base delay for given attempt number
        func calculateBaseDelay(for attempt: Int, baseDelay: TimeInterval = 1.0) -> TimeInterval {
            switch self {
            case .exponential(let base, let multiplier, let maxDelay):
                let delay = base * pow(multiplier, Double(max(0, attempt - 1)))
                return min(delay, maxDelay)
                
            case .linear(let increment, let maxDelay):
                let delay = baseDelay + (increment * Double(max(0, attempt - 1)))
                return min(delay, maxDelay)
                
            case .fixed(let delay):
                return delay
                
            case .fibonacci(let maxDelay):
                let fibDelay = TimeInterval(fibonacci(n: attempt)) * baseDelay
                return min(fibDelay, maxDelay)
                
            case .polynomial(let degree, let coefficient, let maxDelay):
                let delay = coefficient * pow(Double(attempt), Double(degree))
                return min(delay, maxDelay)
            }
        }
        
        private func fibonacci(n: Int) -> Int {
            guard n > 0 else { return 0 }
            guard n > 2 else { return 1 }
            
            var a = 1, b = 1
            for _ in 3...n {
                let temp = a + b
                a = b
                b = temp
            }
            return b
        }
    }
    
    /// Jitter types to add randomness and prevent synchronized retries
    enum Jitter {
        case none
        case uniform(range: ClosedRange<Double>)
        case gaussian(standardDeviation: Double)
        case decorrelated(previousDelay: TimeInterval)
        case exponentialDecay(factor: Double)
        
        /// Apply jitter to the calculated delay
        func apply(to delay: TimeInterval, attempt: Int = 1) -> TimeInterval {
            switch self {
            case .none:
                return delay
                
            case .uniform(let range):
                let factor = Double.random(in: range)
                return max(0, delay * factor)
                
            case .gaussian(let stdDev):
                let jitteredFactor = generateGaussianRandom(mean: 1.0, standardDeviation: stdDev)
                return max(0, delay * jitteredFactor)
                
            case .decorrelated(let previousDelay):
                // Decorrelated jitter: random between 0 and max(delay, previousDelay * 3)
                let maxJitter = max(delay, previousDelay * 3)
                return Double.random(in: 0...maxJitter)
                
            case .exponentialDecay(let factor):
                // Apply exponential decay to jitter amount
                let jitterAmount = delay * factor * pow(0.5, Double(attempt - 1))
                let jitterRange = -jitterAmount...jitterAmount
                return max(0, delay + Double.random(in: jitterRange))
            }
        }
        
        private func generateGaussianRandom(mean: Double, standardDeviation: Double) -> Double {
            // Box-Muller transform for Gaussian distribution
            let u1 = Double.random(in: 0.001...0.999) // Avoid exact 0 for log
            let u2 = Double.random(in: 0...1)
            
            let z0 = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
            return mean + z0 * standardDeviation
        }
    }
    
    /// Configuration for backoff calculation
    struct Configuration {
        let algorithm: Algorithm
        let jitter: Jitter
        let minDelay: TimeInterval
        let maxDelay: TimeInterval
        let baseDelay: TimeInterval
        
        init(
            algorithm: Algorithm = .exponential(base: 1.0, multiplier: 2.0, maxDelay: 60.0),
            jitter: Jitter = .uniform(range: 0.5...1.5),
            minDelay: TimeInterval = 0.1,
            maxDelay: TimeInterval = 300.0,
            baseDelay: TimeInterval = 1.0
        ) {
            self.algorithm = algorithm
            self.jitter = jitter
            self.minDelay = minDelay
            self.maxDelay = maxDelay
            self.baseDelay = baseDelay
        }
        
        /// Predefined configurations for common use cases
        static let immediate = Configuration(
            algorithm: .fixed(delay: 0),
            jitter: .none,
            minDelay: 0,
            maxDelay: 0
        )
        
        static let conservative = Configuration(
            algorithm: .exponential(base: 2.0, multiplier: 2.0, maxDelay: 60.0),
            jitter: .uniform(range: 0.8...1.2),
            minDelay: 1.0,
            maxDelay: 60.0,
            baseDelay: 2.0
        )
        
        static let aggressive = Configuration(
            algorithm: .exponential(base: 0.5, multiplier: 1.5, maxDelay: 30.0),
            jitter: .decorrelated(previousDelay: 0),
            minDelay: 0.1,
            maxDelay: 30.0,
            baseDelay: 0.5
        )
        
        static let linear = Configuration(
            algorithm: .linear(increment: 1.0, maxDelay: 30.0),
            jitter: .uniform(range: 0.9...1.1),
            minDelay: 0.5,
            maxDelay: 30.0,
            baseDelay: 1.0
        )
        
        static let fibonacci = Configuration(
            algorithm: .fibonacci(maxDelay: 60.0),
            jitter: .gaussian(standardDeviation: 0.1),
            minDelay: 1.0,
            maxDelay: 60.0,
            baseDelay: 1.0
        )
    }
    
    private let configuration: Configuration
    private var previousDelay: TimeInterval = 0
    
    init(configuration: Configuration = .conservative) {
        self.configuration = configuration
    }
    
    /// Calculate the backoff delay for a given attempt
    /// - Parameters:
    ///   - attempt: The attempt number (1-based)
    ///   - context: Additional context for specialized jitter calculations
    /// - Returns: The calculated delay in seconds
    mutating func calculateDelay(for attempt: Int, context: BackoffContext = BackoffContext()) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        
        // Calculate base delay using the algorithm
        let baseDelay = configuration.algorithm.calculateBaseDelay(
            for: attempt,
            baseDelay: configuration.baseDelay
        )
        
        // Apply jitter based on configuration
        let jitteredJitter: Jitter
        switch configuration.jitter {
        case .decorrelated:
            jitteredJitter = .decorrelated(previousDelay: previousDelay)
        default:
            jitteredJitter = configuration.jitter
        }
        
        let jitteredDelay = jitteredJitter.apply(to: baseDelay, attempt: attempt)
        
        // Apply min/max constraints
        let finalDelay = max(configuration.minDelay, min(jitteredDelay, configuration.maxDelay))
        
        // Store for next calculation (needed for decorrelated jitter)
        previousDelay = finalDelay
        
        return finalDelay
    }
    
    /// Calculate multiple delays for batch operations
    /// - Parameters:
    ///   - attempts: Array of attempt numbers
    ///   - resetBetweenCalculations: Whether to reset state between calculations
    /// - Returns: Array of calculated delays
    mutating func calculateDelays(for attempts: [Int], resetBetweenCalculations: Bool = false) -> [TimeInterval] {
        var delays: [TimeInterval] = []
        
        for attempt in attempts {
            if resetBetweenCalculations {
                previousDelay = 0
            }
            delays.append(calculateDelay(for: attempt))
        }
        
        return delays
    }
    
    /// Reset internal state (useful for decorrelated jitter)
    mutating func reset() {
        previousDelay = 0
    }
    
    /// Calculate total time for a series of retries
    /// - Parameter maxAttempts: Maximum number of attempts
    /// - Returns: Total time that would be spent on delays
    func calculateTotalTime(for maxAttempts: Int) -> TimeInterval {
        var tempCalculator = self
        let delays = tempCalculator.calculateDelays(for: Array(1...maxAttempts), resetBetweenCalculations: true)
        return delays.reduce(0, +)
    }
    
    /// Generate delay sequence up to a maximum time
    /// - Parameter maxTime: Maximum total time allowed
    /// - Returns: Array of delays that fit within the time constraint
    mutating func generateDelaySequence(maxTime: TimeInterval) -> [TimeInterval] {
        var delays: [TimeInterval] = []
        var totalTime: TimeInterval = 0
        var attempt = 1
        
        reset()
        
        while totalTime < maxTime {
            let delay = calculateDelay(for: attempt)
            if totalTime + delay > maxTime {
                break
            }
            
            delays.append(delay)
            totalTime += delay
            attempt += 1
            
            // Safety check to prevent infinite loops
            if attempt > 1000 {
                break
            }
        }
        
        return delays
    }
}

/// Additional context for backoff calculations
struct BackoffContext {
    let errorType: String?
    let serverResponseTime: TimeInterval?
    let networkLatency: TimeInterval?
    let queueLength: Int?
    
    init(
        errorType: String? = nil,
        serverResponseTime: TimeInterval? = nil,
        networkLatency: TimeInterval? = nil,
        queueLength: Int? = nil
    ) {
        self.errorType = errorType
        self.serverResponseTime = serverResponseTime
        self.networkLatency = networkLatency
        self.queueLength = queueLength
    }
}

/// Convenience extensions for common backoff patterns
extension BackoffCalculator {
    
    /// Create a calculator for network operations
    static func forNetworkOperations() -> BackoffCalculator {
        return BackoffCalculator(configuration: .conservative)
    }
    
    /// Create a calculator for rate limiting scenarios
    static func forRateLimiting() -> BackoffCalculator {
        return BackoffCalculator(configuration: Configuration(
            algorithm: .linear(increment: 5.0, maxDelay: 300.0),
            jitter: .uniform(range: 0.8...1.2),
            minDelay: 1.0,
            maxDelay: 300.0,
            baseDelay: 5.0
        ))
    }
    
    /// Create a calculator for API client operations
    static func forAPIClient() -> BackoffCalculator {
        return BackoffCalculator(configuration: Configuration(
            algorithm: .exponential(base: 1.0, multiplier: 1.5, maxDelay: 60.0),
            jitter: .decorrelated(previousDelay: 0),
            minDelay: 0.5,
            maxDelay: 60.0,
            baseDelay: 1.0
        ))
    }
    
    /// Create a calculator for download retries
    static func forDownloadRetries() -> BackoffCalculator {
        return BackoffCalculator(configuration: Configuration(
            algorithm: .fibonacci(maxDelay: 120.0),
            jitter: .gaussian(standardDeviation: 0.15),
            minDelay: 1.0,
            maxDelay: 120.0,
            baseDelay: 2.0
        ))
    }
}