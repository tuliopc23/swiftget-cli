import Foundation
import Logging

/// Global bandwidth manager that coordinates bandwidth allocation across multiple downloads
/// Uses an actor-based design for thread-safe bandwidth distribution and monitoring
actor GlobalBandwidthManager {
    
    // MARK: - Private Properties
    
    private let logger: Logger
    private let configuration: BandwidthConfiguration
    private var totalBandwidthLimit: Int64 // bytes per second
    private var allocatedBandwidth: Int64 = 0
    private var activeTokens: [UUID: BandwidthToken] = [:]
    private var pendingRequests: [BandwidthRequest] = []
    private var statistics: BandwidthStatistics
    private let startTime: Date
    
    // Bandwidth monitoring
    private var usageHistory: [BandwidthUsageSample] = []
    private let maxHistorySize = 100
    private var lastCleanupTime: Date = Date()
    
    // MARK: - Initialization
    
    init(
        totalBandwidthLimit: Int64,
        configuration: BandwidthConfiguration = .default,
        logger: Logger
    ) {
        self.totalBandwidthLimit = totalBandwidthLimit
        self.configuration = configuration
        self.logger = logger
        self.statistics = BandwidthStatistics()
        self.startTime = Date()
        
        logger.info("GlobalBandwidthManager initialized with limit: \(ByteCountFormatter.string(fromByteCount: totalBandwidthLimit, countStyle: .binary))/s")
    }
    
    // MARK: - Public Interface
    
    /// Request bandwidth allocation for a download
    /// - Parameters:
    ///   - requestedBandwidth: Desired bandwidth in bytes per second
    ///   - priority: Download priority (higher = more important)
    ///   - downloadId: Unique identifier for the download
    ///   - downloadType: Type of download for prioritization
    /// - Returns: BandwidthToken if allocation successful, nil if denied
    func requestBandwidth(
        requestedBandwidth: Int64,
        priority: BandwidthPriority,
        downloadId: UUID,
        downloadType: DownloadType = .general
    ) async -> BandwidthToken? {
        
        await performMaintenanceTasks()
        
        let request = BandwidthRequest(
            requestedBandwidth: requestedBandwidth,
            priority: priority,
            downloadId: downloadId,
            downloadType: downloadType,
            timestamp: Date()
        )
        
        logger.debug("Bandwidth request: \(ByteCountFormatter.string(fromByteCount: requestedBandwidth, countStyle: .binary))/s, priority: \(priority), download: \(downloadId)")
        
        // Try immediate allocation
        if let token = await tryAllocateBandwidth(request: request) {
            activeTokens[token.id] = token
            allocatedBandwidth += token.allocatedBandwidth
            statistics.totalAllocations += 1
            statistics.totalBandwidthRequested += requestedBandwidth
            
            logger.info("Bandwidth allocated: \(ByteCountFormatter.string(fromByteCount: token.allocatedBandwidth, countStyle: .binary))/s to download \(downloadId)")
            return token
        }
        
        // Queue for later allocation if queuing is enabled
        if configuration.enableQueueing {
            pendingRequests.append(request)
            pendingRequests.sort { $0.priority.rawValue > $1.priority.rawValue }
            
            logger.debug("Bandwidth request queued for download \(downloadId)")
            statistics.totalQueuedRequests += 1
            return nil
        }
        
        // Immediate denial
        logger.warning("Bandwidth request denied for download \(downloadId): insufficient available bandwidth")
        statistics.totalDeniedRequests += 1
        return nil
    }
    
    /// Release bandwidth allocation
    /// - Parameter tokenId: Token ID to release
    func releaseBandwidth(tokenId: UUID) async {
        guard let token = activeTokens.removeValue(forKey: tokenId) else {
            logger.warning("Attempted to release unknown bandwidth token: \(tokenId)")
            return
        }
        
        allocatedBandwidth -= token.allocatedBandwidth
        statistics.totalReleases += 1
        
        logger.debug("Bandwidth released: \(ByteCountFormatter.string(fromByteCount: token.allocatedBandwidth, countStyle: .binary))/s from download \(token.downloadId)")
        
        // Try to allocate bandwidth to queued requests
        await processQueuedRequests()
    }
    
    /// Update bandwidth usage for a token
    /// - Parameters:
    ///   - tokenId: Token ID
    ///   - actualUsage: Actual bandwidth usage in bytes per second
    func updateBandwidthUsage(tokenId: UUID, actualUsage: Int64) async {
        guard let token = activeTokens[tokenId] else {
            logger.warning("Attempted to update usage for unknown token: \(tokenId)")
            return
        }
        
        // Update token usage
        let updatedToken = token.withUpdatedUsage(actualUsage: actualUsage)
        activeTokens[tokenId] = updatedToken
        
        // Record usage sample
        let sample = BandwidthUsageSample(
            timestamp: Date(),
            allocatedBandwidth: token.allocatedBandwidth,
            actualUsage: actualUsage,
            downloadId: token.downloadId,
            priority: token.priority
        )
        
        usageHistory.append(sample)
        if usageHistory.count > maxHistorySize {
            usageHistory.removeFirst()
        }
        
        // Trigger reallocation if significant under-usage is detected
        if actualUsage < token.allocatedBandwidth * Int64(configuration.underUsageThreshold) {
            await considerReallocation(underUsedToken: updatedToken)
        }
    }
    
    /// Adjust global bandwidth limit
    /// - Parameter newLimit: New total bandwidth limit in bytes per second
    func adjustBandwidthLimit(_ newLimit: Int64) async {
        let oldLimit = totalBandwidthLimit
        totalBandwidthLimit = newLimit
        
        logger.info("Bandwidth limit adjusted from \(ByteCountFormatter.string(fromByteCount: oldLimit, countStyle: .binary))/s to \(ByteCountFormatter.string(fromByteCount: newLimit, countStyle: .binary))/s")
        
        if newLimit > oldLimit {
            // Increased limit - try to satisfy queued requests
            await processQueuedRequests()
        } else if newLimit < oldLimit && allocatedBandwidth > newLimit {
            // Decreased limit - need to reduce allocations
            await enforceNewLimit()
        }
    }
    
    /// Get current bandwidth statistics
    func getStatistics() async -> BandwidthStatistics {
        await performMaintenanceTasks()
        
        var stats = statistics
        stats.currentAllocatedBandwidth = allocatedBandwidth
        stats.currentAvailableBandwidth = max(0, totalBandwidthLimit - allocatedBandwidth)
        stats.activeDownloads = activeTokens.count
        stats.queuedRequests = pendingRequests.count
        stats.totalBandwidthLimit = totalBandwidthLimit
        stats.uptime = Date().timeIntervalSince(startTime)
        
        // Calculate efficiency metrics
        if !usageHistory.isEmpty {
            let recentSamples = usageHistory.suffix(min(20, usageHistory.count))
            let totalAllocated = recentSamples.reduce(0) { $0 + $1.allocatedBandwidth }
            let totalUsed = recentSamples.reduce(0) { $0 + $1.actualUsage }
            stats.utilizationEfficiency = totalAllocated > 0 ? Double(totalUsed) / Double(totalAllocated) : 0.0
        }
        
        return stats
    }
    
    /// Get information about active bandwidth tokens
    func getActiveTokens() async -> [BandwidthToken] {
        return Array(activeTokens.values)
    }
    
    /// Get queued bandwidth requests
    func getQueuedRequests() async -> [BandwidthRequest] {
        return pendingRequests
    }
    
    // MARK: - Private Methods
    
    private func tryAllocateBandwidth(request: BandwidthRequest) async -> BandwidthToken? {
        let availableBandwidth = totalBandwidthLimit - allocatedBandwidth
        
        // Check if we have enough bandwidth
        guard availableBandwidth > 0 else { return nil }
        
        // Calculate allocation based on priority and availability
        let allocatedAmount = await calculateAllocation(
            requested: request.requestedBandwidth,
            available: availableBandwidth,
            priority: request.priority,
            downloadType: request.downloadType
        )
        
        guard allocatedAmount > 0 else { return nil }
        
        // Create token
        return BandwidthToken(
            id: UUID(),
            downloadId: request.downloadId,
            allocatedBandwidth: allocatedAmount,
            priority: request.priority,
            downloadType: request.downloadType,
            allocationTime: Date(),
            lastUsageUpdate: Date()
        )
    }
    
    private func calculateAllocation(
        requested: Int64,
        available: Int64,
        priority: BandwidthPriority,
        downloadType: DownloadType
    ) async -> Int64 {
        
        // Minimum allocation check
        let minAllocation = max(configuration.minimumAllocation, requested / 10)
        guard available >= minAllocation else { return 0 }
        
        // Base allocation
        var allocation = min(requested, available)
        
        // Apply priority multiplier
        let priorityMultiplier = getPriorityMultiplier(priority: priority)
        allocation = min(allocation, Int64(Double(available) * priorityMultiplier))
        
        // Apply download type considerations
        allocation = applyDownloadTypeAdjustment(allocation: allocation, downloadType: downloadType, available: available)
        
        // Apply fairness constraints
        if activeTokens.count >= configuration.maxConcurrentDownloads {
            allocation = min(allocation, available / Int64(max(1, activeTokens.count + 1)))
        }
        
        return max(minAllocation, allocation)
    }
    
    private func getPriorityMultiplier(priority: BandwidthPriority) -> Double {
        switch priority {
        case .low: return 0.3
        case .normal: return 0.6
        case .high: return 0.8
        case .critical: return 1.0
        }
    }
    
    private func applyDownloadTypeAdjustment(allocation: Int64, downloadType: DownloadType, available: Int64) -> Int64 {
        switch downloadType {
        case .general:
            return allocation
        case .userInitiated:
            return min(allocation * 3 / 2, available) // 50% boost for user-initiated
        case .background:
            return allocation * 2 / 3 // Reduce background downloads
        case .system:
            return min(allocation * 2, available) // Double for system downloads
        case .streaming:
            return allocation // Streaming gets what it asks for
        }
    }
    
    private func processQueuedRequests() async {
        guard !pendingRequests.isEmpty else { return }
        
        var processedRequests: [Int] = []
        
        for (index, request) in pendingRequests.enumerated() {
            if let token = await tryAllocateBandwidth(request: request) {
                activeTokens[token.id] = token
                allocatedBandwidth += token.allocatedBandwidth
                statistics.totalAllocations += 1
                processedRequests.append(index)
                
                logger.info("Queued bandwidth request satisfied: \(ByteCountFormatter.string(fromByteCount: token.allocatedBandwidth, countStyle: .binary))/s to download \(request.downloadId)")
            }
        }
        
        // Remove processed requests (in reverse order to maintain indices)
        for index in processedRequests.reversed() {
            pendingRequests.remove(at: index)
        }
    }
    
    private func considerReallocation(underUsedToken: BandwidthToken) async {
        let underUsage = underUsedToken.allocatedBandwidth - (underUsedToken.lastReportedUsage ?? 0)
        
        // Only reallocate if under-usage is significant
        guard underUsage > configuration.minimumAllocation else { return }
        
        logger.debug("Considering reallocation due to under-usage: \(ByteCountFormatter.string(fromByteCount: underUsage, countStyle: .binary))/s from download \(underUsedToken.downloadId)")
        
        // For now, just log - actual reallocation would require more complex logic
        // In a full implementation, we might reduce the allocation and offer it to queued requests
    }
    
    private func enforceNewLimit() async {
        let excessBandwidth = allocatedBandwidth - totalBandwidthLimit
        guard excessBandwidth > 0 else { return }
        
        logger.warning("Need to reduce allocations by \(ByteCountFormatter.string(fromByteCount: excessBandwidth, countStyle: .binary))/s due to limit reduction")
        
        // Sort tokens by priority (lowest first for reduction)
        let sortedTokens = activeTokens.values.sorted { $0.priority.rawValue < $1.priority.rawValue }
        
        var remainingReduction = excessBandwidth
        var tokensToUpdate: [(UUID, Int64)] = []
        
        for token in sortedTokens {
            guard remainingReduction > 0 else { break }
            
            let reductionAmount = min(remainingReduction, token.allocatedBandwidth / 2)
            if reductionAmount > 0 {
                tokensToUpdate.append((token.id, token.allocatedBandwidth - reductionAmount))
                remainingReduction -= reductionAmount
            }
        }
        
        // Apply reductions
        for (tokenId, newAllocation) in tokensToUpdate {
            if var token = activeTokens[tokenId] {
                let oldAllocation = token.allocatedBandwidth
                token = token.withNewAllocation(newAllocation)
                activeTokens[tokenId] = token
                allocatedBandwidth = allocatedBandwidth - oldAllocation + newAllocation
                
                logger.info("Reduced bandwidth allocation for download \(token.downloadId) from \(ByteCountFormatter.string(fromByteCount: oldAllocation, countStyle: .binary))/s to \(ByteCountFormatter.string(fromByteCount: newAllocation, countStyle: .binary))/s")
            }
        }
    }
    
    private func performMaintenanceTasks() async {
        let now = Date()
        
        // Only run maintenance periodically
        guard now.timeIntervalSince(lastCleanupTime) > configuration.maintenanceInterval else { return }
        lastCleanupTime = now
        
        // Clean up stale tokens
        let staleThreshold = now.addingTimeInterval(-configuration.tokenExpirationTime)
        let staleTokenIds = activeTokens.compactMap { (id, token) in
            token.lastUsageUpdate < staleThreshold ? id : nil
        }
        
        for tokenId in staleTokenIds {
            logger.warning("Removing stale bandwidth token: \(tokenId)")
            await releaseBandwidth(tokenId: tokenId)
        }
        
        // Clean up old usage history
        let historyThreshold = now.addingTimeInterval(-configuration.usageHistoryRetention)
        usageHistory.removeAll { $0.timestamp < historyThreshold }
        
        // Clean up old queued requests
        let requestThreshold = now.addingTimeInterval(-configuration.queueTimeout)
        let originalCount = pendingRequests.count
        pendingRequests.removeAll { $0.timestamp < requestThreshold }
        
        if pendingRequests.count < originalCount {
            logger.info("Cleaned up \(originalCount - pendingRequests.count) expired queued requests")
        }
    }
}

// MARK: - Supporting Types

/// Bandwidth allocation priority levels
enum BandwidthPriority: Int, CaseIterable, Comparable {
    case low = 1
    case normal = 2
    case high = 3
    case critical = 4
    
    static func < (lhs: BandwidthPriority, rhs: BandwidthPriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// Types of downloads for bandwidth allocation decisions
enum DownloadType: String, CaseIterable {
    case general = "general"
    case userInitiated = "user_initiated"
    case background = "background"
    case system = "system"
    case streaming = "streaming"
}

/// Configuration for bandwidth management behavior
struct BandwidthConfiguration {
    let minimumAllocation: Int64 // Minimum bytes per second to allocate
    let maxConcurrentDownloads: Int
    let enableQueueing: Bool
    let underUsageThreshold: Double // Threshold for detecting under-usage (0.0-1.0)
    let maintenanceInterval: TimeInterval
    let tokenExpirationTime: TimeInterval
    let usageHistoryRetention: TimeInterval
    let queueTimeout: TimeInterval
    
    static let `default` = BandwidthConfiguration(
        minimumAllocation: 1024, // 1 KB/s minimum
        maxConcurrentDownloads: 10,
        enableQueueing: true,
        underUsageThreshold: 0.5, // 50% under-usage threshold
        maintenanceInterval: 30.0, // 30 seconds
        tokenExpirationTime: 300.0, // 5 minutes
        usageHistoryRetention: 3600.0, // 1 hour
        queueTimeout: 600.0 // 10 minutes
    )
    
    static let aggressive = BandwidthConfiguration(
        minimumAllocation: 512,
        maxConcurrentDownloads: 20,
        enableQueueing: true,
        underUsageThreshold: 0.3,
        maintenanceInterval: 15.0,
        tokenExpirationTime: 180.0,
        usageHistoryRetention: 1800.0,
        queueTimeout: 300.0
    )
    
    static let conservative = BandwidthConfiguration(
        minimumAllocation: 2048,
        maxConcurrentDownloads: 5,
        enableQueueing: false,
        underUsageThreshold: 0.7,
        maintenanceInterval: 60.0,
        tokenExpirationTime: 600.0,
        usageHistoryRetention: 7200.0,
        queueTimeout: 1200.0
    )
}

/// Request for bandwidth allocation
struct BandwidthRequest {
    let requestedBandwidth: Int64
    let priority: BandwidthPriority
    let downloadId: UUID
    let downloadType: DownloadType
    let timestamp: Date
}

/// Sample of bandwidth usage for monitoring
struct BandwidthUsageSample {
    let timestamp: Date
    let allocatedBandwidth: Int64
    let actualUsage: Int64
    let downloadId: UUID
    let priority: BandwidthPriority
    
    var utilizationRatio: Double {
        return allocatedBandwidth > 0 ? Double(actualUsage) / Double(allocatedBandwidth) : 0.0
    }
}

/// Statistics for bandwidth management monitoring
struct BandwidthStatistics {
    var totalAllocations: Int = 0
    var totalReleases: Int = 0
    var totalDeniedRequests: Int = 0
    var totalQueuedRequests: Int = 0
    var totalBandwidthRequested: Int64 = 0
    
    // Current state (populated when requested)
    var currentAllocatedBandwidth: Int64 = 0
    var currentAvailableBandwidth: Int64 = 0
    var activeDownloads: Int = 0
    var queuedRequests: Int = 0
    var totalBandwidthLimit: Int64 = 0
    var uptime: TimeInterval = 0
    var utilizationEfficiency: Double = 0.0
    
    var allocationSuccessRate: Double {
        let totalRequests = totalAllocations + totalDeniedRequests
        return totalRequests > 0 ? Double(totalAllocations) / Double(totalRequests) : 0.0
    }
    
    var averageRequestSize: Int64 {
        return totalAllocations > 0 ? totalBandwidthRequested / Int64(totalAllocations) : 0
    }
}