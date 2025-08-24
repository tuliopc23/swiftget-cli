import Foundation
import Logging

/// Enhanced speed limiter that integrates with GlobalBandwidthManager for coordinated bandwidth limiting
/// Supports both standalone operation and token-based bandwidth allocation
actor SpeedLimiter {
    
    // MARK: - Configuration
    
    /// Configuration for speed limiting behavior
    struct Configuration {
        let windowSize: TimeInterval
        let burstAllowance: Double // Multiplier for burst allowance (e.g., 1.5 = 50% burst)
        let reportingInterval: TimeInterval // How often to report usage to bandwidth manager
        let adaptiveThrottling: Bool // Whether to adapt based on network conditions
        
        static let `default` = Configuration(
            windowSize: 1.0,
            burstAllowance: 1.2,
            reportingInterval: 0.5,
            adaptiveThrottling: true
        )
        
        static let strict = Configuration(
            windowSize: 0.5,
            burstAllowance: 1.0,
            reportingInterval: 0.2,
            adaptiveThrottling: false
        )
        
        static let lenient = Configuration(
            windowSize: 2.0,
            burstAllowance: 2.0,
            reportingInterval: 1.0,
            adaptiveThrottling: true
        )
    }
    
    // MARK: - Properties
    
    private let configuration: Configuration
    private let logger: Logger?
    
    // Standalone mode properties
    private let maxBytesPerSecond: Int64?
    
    // Token-based mode properties
    private var bandwidthToken: BandwidthToken?
    private weak var bandwidthManager: GlobalBandwidthManager?
    
    // Throttling state
    private var windowStart: Date
    private var bytesInWindow: Int64
    private var lastReportTime: Date
    private var totalBytesProcessed: Int64
    private var lastReportedUsage: Int64
    
    // Performance metrics
    private var usageHistory: [(timestamp: Date, bytesPerSecond: Int64)] = []
    private let maxHistorySize = 20
    
    // MARK: - Initialization
    
    /// Initialize for standalone speed limiting
    init(maxBytesPerSecond: Int64, configuration: Configuration = .default, logger: Logger? = nil) {
        self.maxBytesPerSecond = maxBytesPerSecond
        self.configuration = configuration
        self.logger = logger
        self.bandwidthToken = nil
        self.bandwidthManager = nil
        
        let now = Date()
        self.windowStart = now
        self.lastReportTime = now
        self.bytesInWindow = 0
        self.totalBytesProcessed = 0
        self.lastReportedUsage = 0
        
        logger?.debug("SpeedLimiter initialized in standalone mode with limit: \(ByteCountFormatter.string(fromByteCount: maxBytesPerSecond, countStyle: .binary))/s")
    }
    
    /// Initialize for token-based bandwidth management
    init(
        bandwidthToken: BandwidthToken,
        bandwidthManager: GlobalBandwidthManager,
        configuration: Configuration = .default,
        logger: Logger? = nil
    ) {
        self.maxBytesPerSecond = nil
        self.bandwidthToken = bandwidthToken
        self.bandwidthManager = bandwidthManager
        self.configuration = configuration
        self.logger = logger
        
        let now = Date()
        self.windowStart = now
        self.lastReportTime = now
        self.bytesInWindow = 0
        self.totalBytesProcessed = 0
        self.lastReportedUsage = 0
        
        logger?.debug("SpeedLimiter initialized in token mode with allocation: \(ByteCountFormatter.string(fromByteCount: bandwidthToken.allocatedBandwidth, countStyle: .binary))/s")
    }
    
    // MARK: - Public Interface
    
    /// Update the bandwidth token (for token-based mode)
    func updateBandwidthToken(_ newToken: BandwidthToken) {
        bandwidthToken = newToken
        logger?.debug("Bandwidth token updated to: \(ByteCountFormatter.string(fromByteCount: newToken.allocatedBandwidth, countStyle: .binary))/s")
    }
    
    /// Main throttling function - processes bytes and applies speed limiting
    func throttle(wrote bytes: Int) async {
        let bytesInt64 = Int64(bytes)
        totalBytesProcessed += bytesInt64
        bytesInWindow += bytesInt64
        
        let now = Date()
        let windowElapsed = now.timeIntervalSince(windowStart)
        let reportElapsed = now.timeIntervalSince(lastReportTime)
        
        // Get current bandwidth limit
        let currentLimit = getCurrentBandwidthLimit()
        
        // Calculate burst allowance
        let burstLimit = Int64(Double(currentLimit) * configuration.burstAllowance)
        
        // Check if we need to throttle
        if windowElapsed < configuration.windowSize {
            if bytesInWindow > burstLimit {
                // Calculate required sleep time
                let targetRate = Double(currentLimit)
                let currentRate = Double(bytesInWindow) / windowElapsed
                
                if currentRate > targetRate {
                    let requiredTimeForCurrentBytes = Double(bytesInWindow) / targetRate
                    let sleepTime = requiredTimeForCurrentBytes - windowElapsed
                    
                    if sleepTime > 0 {
                        logger?.debug("Throttling: sleeping for \(String(format: "%.3f", sleepTime))s (rate: \(String(format: "%.1f", currentRate)) B/s, target: \(String(format: "%.1f", targetRate)) B/s)")
                        
                        let nanoseconds = UInt64(sleepTime * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: nanoseconds)
                    }
                }
            }
        } else {
            // Window has elapsed, reset and record usage
            await recordUsageMetrics(bytesInWindow: bytesInWindow, windowDuration: windowElapsed)
            resetWindow()
        }
        
        // Report usage to bandwidth manager periodically
        if reportElapsed >= configuration.reportingInterval {
            await reportUsageToManager()
        }
    }
    
    /// Get current speed statistics
    func getSpeedStatistics() -> SpeedStatistics {
        let now = Date()
        let windowElapsed = now.timeIntervalSince(windowStart)
        let currentRate = windowElapsed > 0 ? Int64(Double(bytesInWindow) / windowElapsed) : 0
        
        let averageRate: Int64
        if !usageHistory.isEmpty {
            let totalUsage = usageHistory.reduce(0) { $0 + $1.bytesPerSecond }
            averageRate = totalUsage / Int64(usageHistory.count)
        } else {
            averageRate = 0
        }
        
        return SpeedStatistics(
            currentRate: currentRate,
            averageRate: averageRate,
            totalBytesProcessed: totalBytesProcessed,
            bandwidthLimit: getCurrentBandwidthLimit(),
            utilizationRatio: getCurrentUtilizationRatio(),
            isThrottling: isCurrentlyThrottling()
        )
    }
    
    /// Check if speed limiter is currently active
    var isActive: Bool {
        return getCurrentBandwidthLimit() > 0
    }
    
    /// Get current bandwidth utilization as percentage (0.0 to 1.0)
    func getCurrentUtilizationRatio() -> Double {
        let limit = getCurrentBandwidthLimit()
        guard limit > 0 else { return 0.0 }
        
        let windowElapsed = Date().timeIntervalSince(windowStart)
        guard windowElapsed > 0 else { return 0.0 }
        
        let currentRate = Double(bytesInWindow) / windowElapsed
        return min(1.0, currentRate / Double(limit))
    }
    
    // MARK: - Private Methods
    
    private func getCurrentBandwidthLimit() -> Int64 {
        if let token = bandwidthToken {
            return token.allocatedBandwidth
        } else if let maxBytes = maxBytesPerSecond {
            return maxBytes
        } else {
            return 0 // No limit
        }
    }
    
    private func resetWindow() {
        windowStart = Date()
        bytesInWindow = 0
    }
    
    private func isCurrentlyThrottling() -> Bool {
        let limit = getCurrentBandwidthLimit()
        guard limit > 0 else { return false }
        
        let windowElapsed = Date().timeIntervalSince(windowStart)
        guard windowElapsed > 0 else { return false }
        
        let currentRate = Double(bytesInWindow) / windowElapsed
        return currentRate > Double(limit) * 0.9 // Consider throttling if > 90% of limit
    }
    
    private func recordUsageMetrics(bytesInWindow: Int64, windowDuration: TimeInterval) async {
        guard windowDuration > 0 else { return }
        
        let bytesPerSecond = Int64(Double(bytesInWindow) / windowDuration)
        
        // Add to history
        usageHistory.append((timestamp: Date(), bytesPerSecond: bytesPerSecond))
        if usageHistory.count > maxHistorySize {
            usageHistory.removeFirst()
        }
        
        logger?.debug("Usage metrics: \(ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .binary))/s over \(String(format: "%.2f", windowDuration))s window")
    }
    
    private func reportUsageToManager() async {
        guard let manager = bandwidthManager,
              let token = bandwidthToken else { return }
        
        let windowElapsed = Date().timeIntervalSince(windowStart)
        let reportElapsed = Date().timeIntervalSince(lastReportTime)
        
        // Calculate current usage rate
        let currentUsage: Int64
        if reportElapsed > 0 {
            let bytesInReportWindow = totalBytesProcessed - lastReportedUsage
            currentUsage = Int64(Double(bytesInReportWindow) / reportElapsed)
        } else {
            currentUsage = windowElapsed > 0 ? Int64(Double(bytesInWindow) / windowElapsed) : 0
        }
        
        // Report to bandwidth manager
        await manager.updateBandwidthUsage(tokenId: token.id, actualUsage: currentUsage)
        
        lastReportTime = Date()
        lastReportedUsage = totalBytesProcessed
        
        logger?.debug("Reported usage to bandwidth manager: \(ByteCountFormatter.string(fromByteCount: currentUsage, countStyle: .binary))/s")
    }
}

// MARK: - Supporting Types

/// Statistics about current speed limiting performance
struct SpeedStatistics: Sendable {
    let currentRate: Int64 // Current bytes per second
    let averageRate: Int64 // Average bytes per second over recent history
    let totalBytesProcessed: Int64 // Total bytes processed
    let bandwidthLimit: Int64 // Current bandwidth limit
    let utilizationRatio: Double // Current utilization (0.0 to 1.0)
    let isThrottling: Bool // Whether currently throttling
    
    /// Formatted current rate as human-readable string
    var formattedCurrentRate: String {
        return ByteCountFormatter.string(fromByteCount: currentRate, countStyle: .binary) + "/s"
    }
    
    /// Formatted average rate as human-readable string
    var formattedAverageRate: String {
        return ByteCountFormatter.string(fromByteCount: averageRate, countStyle: .binary) + "/s"
    }
    
    /// Formatted bandwidth limit as human-readable string
    var formattedBandwidthLimit: String {
        return ByteCountFormatter.string(fromByteCount: bandwidthLimit, countStyle: .binary) + "/s"
    }
    
    /// Utilization percentage as formatted string
    var formattedUtilization: String {
        return String(format: "%.1f%%", utilizationRatio * 100)
    }
}

// MARK: - Factory Methods

extension SpeedLimiter {
    
    /// Create a speed limiter for high-priority downloads
    static func forHighPriorityDownload(
        maxBytesPerSecond: Int64,
        logger: Logger? = nil
    ) -> SpeedLimiter {
        return SpeedLimiter(
            maxBytesPerSecond: maxBytesPerSecond,
            configuration: .lenient,
            logger: logger
        )
    }
    
    /// Create a speed limiter for background downloads
    static func forBackgroundDownload(
        maxBytesPerSecond: Int64,
        logger: Logger? = nil
    ) -> SpeedLimiter {
        return SpeedLimiter(
            maxBytesPerSecond: maxBytesPerSecond,
            configuration: .strict,
            logger: logger
        )
    }
    
    /// Create a speed limiter with bandwidth token
    static func withBandwidthToken(
        token: BandwidthToken,
        manager: GlobalBandwidthManager,
        logger: Logger? = nil
    ) -> SpeedLimiter {
        return SpeedLimiter(
            bandwidthToken: token,
            bandwidthManager: manager,
            configuration: .default,
            logger: logger
        )
    }
}

// MARK: - Convenience Extensions

// Note: CustomStringConvertible removed due to actor isolation requirements
// Use the getSpeedStatistics() method to get formatted information