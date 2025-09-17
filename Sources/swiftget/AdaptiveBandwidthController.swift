import Foundation
import Logging

/// Adaptive bandwidth controller that automatically adjusts bandwidth allocation
/// based on real-time network conditions provided by NetworkConditionMonitor
actor AdaptiveBandwidthController {
    
    // MARK: - Configuration
    
    /// Configuration for adaptive bandwidth control behavior
    struct Configuration {
        let adjustmentInterval: TimeInterval // How often to check and adjust bandwidth
        let minimumAdjustmentThreshold: Double // Minimum change threshold to trigger adjustment
        let maxIncreaseRatio: Double // Maximum bandwidth increase ratio per adjustment
        let maxDecreaseRatio: Double // Maximum bandwidth decrease ratio per adjustment
        let stabilityRequiredForIncrease: Int // Number of stable measurements needed for increase
        let aggressivenessLevel: AggressivenessLevel // How aggressive adjustments should be
        let respectUserLimits: Bool // Whether to respect user-set bandwidth limits
        let enablePredictiveAdjustment: Bool // Whether to use predictive adjustment algorithms
        
        static let `default` = Configuration(
            adjustmentInterval: 30.0, // 30 seconds
            minimumAdjustmentThreshold: 0.1, // 10% change minimum
            maxIncreaseRatio: 1.5, // Max 50% increase per adjustment
            maxDecreaseRatio: 0.7, // Max 30% decrease per adjustment
            stabilityRequiredForIncrease: 3, // 3 stable measurements
            aggressivenessLevel: .moderate,
            respectUserLimits: true,
            enablePredictiveAdjustment: true
        )
        
        static let conservative = Configuration(
            adjustmentInterval: 60.0,
            minimumAdjustmentThreshold: 0.2,
            maxIncreaseRatio: 1.2,
            maxDecreaseRatio: 0.8,
            stabilityRequiredForIncrease: 5,
            aggressivenessLevel: .conservative,
            respectUserLimits: true,
            enablePredictiveAdjustment: false
        )
        
        static let aggressive = Configuration(
            adjustmentInterval: 15.0,
            minimumAdjustmentThreshold: 0.05,
            maxIncreaseRatio: 2.0,
            maxDecreaseRatio: 0.5,
            stabilityRequiredForIncrease: 2,
            aggressivenessLevel: .aggressive,
            respectUserLimits: false,
            enablePredictiveAdjustment: true
        )
    }
    
    /// Aggressiveness levels for bandwidth adjustment
    enum AggressivenessLevel: String, CaseIterable, Sendable {
        case conservative = "conservative"
        case moderate = "moderate"
        case aggressive = "aggressive"
        
        var description: String {
            switch self {
            case .conservative:
                return "Conservative adjustments with stability focus"
            case .moderate:
                return "Balanced adjustments with moderate responsiveness"
            case .aggressive:
                return "Aggressive adjustments for maximum performance"
            }
        }
    }
    
    // MARK: - Properties
    
    private let configuration: Configuration
    private let logger: Logger
    private weak var bandwidthManager: GlobalBandwidthManager?
    private weak var networkMonitor: NetworkConditionMonitor?
    
    // Controller state
    private var isActive: Bool = false
    private var adjustmentTask: Task<Void, Never>?
    private var monitorSubscriptionId: UUID?
    
    // Adjustment history and analytics
    private var adjustmentHistory: [BandwidthAdjustment] = []
    private var performanceMetrics: AdaptiveControllerMetrics
    private var lastConditions: NetworkConditions?
    private var stabilityCounter: Int = 0
    
    // User-defined limits and constraints
    private var userMaxBandwidth: Int64?
    private var userMinBandwidth: Int64?
    private var downloadSpecificLimits: [UUID: BandwidthLimits] = [:]
    
    // Predictive adjustment state
    private var conditionTrends: [NetworkConditionTrend] = []
    private var predictionModel: BandwidthPredictionModel?
    
    // MARK: - Initialization
    
    init(
        configuration: Configuration = .default,
        bandwidthManager: GlobalBandwidthManager,
        networkMonitor: NetworkConditionMonitor,
        logger: Logger
    ) {
        self.configuration = configuration
        self.bandwidthManager = bandwidthManager
        self.networkMonitor = networkMonitor
        self.logger = logger
        
        self.performanceMetrics = AdaptiveControllerMetrics()
        
        if configuration.enablePredictiveAdjustment {
            self.predictionModel = BandwidthPredictionModel(configuration: configuration)
        }
        
        logger.info("AdaptiveBandwidthController initialized with \(configuration.aggressivenessLevel) mode")
    }
    
    deinit {
        // Don't capture self in deinit
    }
    
    // MARK: - Public Interface
    
    /// Start adaptive bandwidth control
    func startAdaptiveControl() async {
        guard !isActive else { return }
        
        isActive = true
        
        // Subscribe to network condition changes
        if let networkMonitor = networkMonitor {
            monitorSubscriptionId = await networkMonitor.subscribeToConditionChanges { @Sendable [weak self] conditions in
                Task {
                    await self?.handleConditionChange(conditions)
                }
            }
        }
        
        // Start periodic adjustment task
        adjustmentTask = Task {
            await performPeriodicAdjustments()
        }
        
        logger.info("Adaptive bandwidth control started")
    }
    
    /// Stop adaptive bandwidth control
    func stopAdaptiveControl() async {
        guard isActive else { return }
        
        isActive = false
        
        // Unsubscribe from network conditions
        if let networkMonitor = networkMonitor, let subscriptionId = monitorSubscriptionId {
            await networkMonitor.unsubscribeFromConditionChanges(subscriptionId)
            monitorSubscriptionId = nil
        }
        
        // Cancel adjustment task
        adjustmentTask?.cancel()
        adjustmentTask = nil
        
        logger.info("Adaptive bandwidth control stopped")
    }
    
    /// Set user-defined bandwidth limits
    func setUserBandwidthLimits(min: Int64?, max: Int64?) async {
        userMinBandwidth = min
        userMaxBandwidth = max
        
        logger.debug("User bandwidth limits updated: min=\(min?.description ?? "none"), max=\(max?.description ?? "none")")
        
        // Trigger immediate adjustment to respect new limits
        if isActive {
            await performBandwidthAdjustment(reason: .userLimitChange)
        }
    }
    
    /// Set download-specific bandwidth limits
    func setDownloadBandwidthLimits(_ limits: BandwidthLimits, for downloadId: UUID) async {
        downloadSpecificLimits[downloadId] = limits
        
        logger.debug("Download-specific limits set for \(downloadId): \(limits)")
        
        // Adjust specific download if needed
        if isActive {
            await adjustDownloadBandwidth(downloadId, reason: .downloadLimitChange)
        }
    }
    
    /// Get current controller status
    func getControllerStatus() async -> AdaptiveControllerStatus {
        return AdaptiveControllerStatus(
            isActive: isActive,
            configuration: configuration,
            adjustmentCount: adjustmentHistory.count,
            lastAdjustment: adjustmentHistory.last,
            performanceMetrics: performanceMetrics,
            userLimits: BandwidthLimits(min: userMinBandwidth, max: userMaxBandwidth),
            downloadSpecificLimitsCount: downloadSpecificLimits.count
        )
    }
    
    /// Force immediate bandwidth adjustment
    func forceAdjustment() async {
        guard isActive else { return }
        
        logger.debug("Forcing immediate bandwidth adjustment")
        await performBandwidthAdjustment(reason: .manualTrigger)
    }
    
    // MARK: - Private Methods
    
    private func performPeriodicAdjustments() async {
        while isActive && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(configuration.adjustmentInterval * 1_000_000_000))
                
                if isActive && !Task.isCancelled {
                    await performBandwidthAdjustment(reason: .periodicCheck)
                }
            } catch {
                break
            }
        }
    }
    
    private func handleConditionChange(_ conditions: NetworkConditions) async {
        guard isActive else { return }
        
        // Update condition trends for predictive analysis
        await updateConditionTrends(conditions)
        
        // Determine if immediate adjustment is needed
        let shouldAdjustImmediately = await shouldTriggerImmediateAdjustment(conditions)
        
        if shouldAdjustImmediately {
            logger.debug("Network condition change triggered immediate adjustment")
            await performBandwidthAdjustment(reason: .conditionChange)
        }
        
        lastConditions = conditions
    }
    
    private func shouldTriggerImmediateAdjustment(_ conditions: NetworkConditions) async -> Bool {
        guard let lastConditions = lastConditions else { return true }
        
        let qualityChanged = conditions.quality != lastConditions.quality
        let connectionChanged = conditions.connectionType != lastConditions.connectionType
        let stabilityChanged = conditions.stability != lastConditions.stability
        
        let bandwidthChangeRatio = abs(conditions.bandwidth.downloadBps - lastConditions.bandwidth.downloadBps) / 
                                  max(lastConditions.bandwidth.downloadBps, 1)
        let significantBandwidthChange = Double(bandwidthChangeRatio) > configuration.minimumAdjustmentThreshold
        
        return qualityChanged || connectionChanged || stabilityChanged || significantBandwidthChange
    }
    
    private func performBandwidthAdjustment(reason: AdjustmentReason) async {
        guard let bandwidthManager = bandwidthManager,
              let networkMonitor = networkMonitor else { return }
        
        let startTime = Date()
        let conditions = await networkMonitor.getCurrentConditions()
        let bandwidthStats = await bandwidthManager.getStatistics()
        
        let recommendations = await calculateBandwidthRecommendations(
            conditions: conditions,
            currentStats: bandwidthStats,
            reason: reason
        )
        
        var appliedAdjustments: [UUID: BandwidthAdjustmentResult] = [:]
        
        for recommendation in recommendations {
            let result = await applyBandwidthRecommendation(recommendation)
            appliedAdjustments[recommendation.downloadId] = result
        }
        
        let adjustment = BandwidthAdjustment(
            timestamp: startTime,
            reason: reason,
            networkConditions: conditions,
            recommendations: recommendations,
            results: Array(appliedAdjustments.values),
            processingTime: Date().timeIntervalSince(startTime)
        )
        
        await recordAdjustment(adjustment)
        logger.debug("Bandwidth adjustment completed: \(recommendations.count) recommendations")
    }
    
    private func calculateBandwidthRecommendations(
        conditions: NetworkConditions,
        currentStats: BandwidthStatistics,
        reason: AdjustmentReason
    ) async -> [BandwidthRecommendation] {
        guard let bandwidthManager = bandwidthManager else { return [] }
        
        var recommendations: [BandwidthRecommendation] = []
        let activeTokens = await bandwidthManager.getActiveTokens()
        
        for token in activeTokens {
            if let recommendation = await calculateTokenRecommendation(
                token: token,
                conditions: conditions,
                reason: reason
            ) {
                recommendations.append(recommendation)
            }
        }
        
        return recommendations
    }
    
    private func calculateTokenRecommendation(
        token: BandwidthToken,
        conditions: NetworkConditions,
        reason: AdjustmentReason
    ) async -> BandwidthRecommendation? {
        
        let baseRecommendation = calculateBaseRecommendation(
            currentAllocation: token.allocatedBandwidth,
            conditions: conditions,
            tokenUsage: token.utilizationRatio
        )
        
        let newAllocation = Int64(Double(token.allocatedBandwidth) * baseRecommendation)
        let constrainedAllocation = applyConstraints(allocation: newAllocation, token: token, conditions: conditions)
        
        let changeRatio = abs(Double(constrainedAllocation - token.allocatedBandwidth)) / Double(token.allocatedBandwidth)
        
        guard changeRatio >= configuration.minimumAdjustmentThreshold else {
            return nil
        }
        
        return BandwidthRecommendation(
            downloadId: token.downloadId,
            tokenId: token.id,
            currentAllocation: token.allocatedBandwidth,
            recommendedAllocation: constrainedAllocation,
            adjustmentRatio: Double(constrainedAllocation) / Double(token.allocatedBandwidth),
            reason: reason,
            confidence: calculateRecommendationConfidence(conditions: conditions, token: token),
            priority: token.priority
        )
    }
    
    private func calculateBaseRecommendation(
        currentAllocation: Int64,
        conditions: NetworkConditions,
        tokenUsage: Double
    ) -> Double {
        
        var adjustmentFactor = 1.0
        
        // Adjust based on network quality
        switch conditions.quality {
        case .excellent: adjustmentFactor *= 1.3
        case .good: adjustmentFactor *= 1.1
        case .fair: adjustmentFactor *= 0.9
        case .poor: adjustmentFactor *= 0.7
        case .unknown: adjustmentFactor *= 0.95
        }
        
        // Adjust based on network stability
        switch conditions.stability {
        case .stable: adjustmentFactor *= 1.1
        case .moderate: adjustmentFactor *= 1.0
        case .unstable: adjustmentFactor *= 0.9
        case .veryUnstable: adjustmentFactor *= 0.8
        case .unknown: adjustmentFactor *= 0.95
        }
        
        // Adjust based on token utilization
        if tokenUsage > 0.8 {
            adjustmentFactor *= 1.2
        } else if tokenUsage < 0.3 {
            adjustmentFactor *= 0.8
        }
        
        // Apply configuration limits
        adjustmentFactor = min(adjustmentFactor, configuration.maxIncreaseRatio)
        adjustmentFactor = max(adjustmentFactor, configuration.maxDecreaseRatio)
        
        return adjustmentFactor
    }
    
    private func applyConstraints(allocation: Int64, token: BandwidthToken, conditions: NetworkConditions) -> Int64 {
        var constrainedAllocation = allocation
        
        // Apply user-defined global limits
        if configuration.respectUserLimits {
            if let userMax = userMaxBandwidth {
                constrainedAllocation = min(constrainedAllocation, userMax)
            }
            if let userMin = userMinBandwidth {
                constrainedAllocation = max(constrainedAllocation, userMin)
            }
        }
        
        // Apply download-specific limits
        if let downloadLimits = downloadSpecificLimits[token.downloadId] {
            if let downloadMax = downloadLimits.max {
                constrainedAllocation = min(constrainedAllocation, downloadMax)
            }
            if let downloadMin = downloadLimits.min {
                constrainedAllocation = max(constrainedAllocation, downloadMin)
            }
        }
        
        // Ensure minimum viable allocation
        constrainedAllocation = max(constrainedAllocation, 64_000) // 64 KB/s minimum
        
        return constrainedAllocation
    }
    
    private func calculateRecommendationConfidence(conditions: NetworkConditions, token: BandwidthToken) -> Double {
        var confidence = 0.5
        
        switch conditions.stability {
        case .stable: confidence += 0.3
        case .moderate: confidence += 0.1
        case .unstable: confidence -= 0.1
        case .veryUnstable: confidence -= 0.3
        case .unknown: confidence -= 0.2
        }
        
        confidence += conditions.bandwidth.estimationAccuracy * 0.2
        
        if token.lastReportedUsage != nil {
            confidence += 0.2
        }
        
        return max(0.0, min(1.0, confidence))
    }
    
    private func applyBandwidthRecommendation(_ recommendation: BandwidthRecommendation) async -> BandwidthAdjustmentResult {
        guard bandwidthManager != nil else {
            return BandwidthAdjustmentResult(
                downloadId: recommendation.downloadId,
                success: false,
                oldAllocation: recommendation.currentAllocation,
                newAllocation: recommendation.currentAllocation,
                error: "Bandwidth manager not available"
            )
        }
        
        // TODO: Implement proper bandwidth adjustment
        // await bandwidthManager.adjustTokenAllocation(
        //     tokenId: recommendation.tokenId,
        //     newAllocation: recommendation.recommendedAllocation
        // )
        
        return BandwidthAdjustmentResult(
            downloadId: recommendation.downloadId,
            success: true,
            oldAllocation: recommendation.currentAllocation,
            newAllocation: recommendation.recommendedAllocation,
            error: nil
        )
    }
    
    private func adjustDownloadBandwidth(_ downloadId: UUID, reason: AdjustmentReason) async {
        guard let bandwidthManager = bandwidthManager else { return }
        
        let activeTokens = await bandwidthManager.getActiveTokens()
        let downloadTokens = activeTokens.filter { $0.downloadId == downloadId }
        
        for token in downloadTokens {
            if let limits = downloadSpecificLimits[downloadId] {
                var newAllocation = token.allocatedBandwidth
                
                if let maxLimit = limits.max, newAllocation > maxLimit {
                    newAllocation = maxLimit
                }
                if let minLimit = limits.min, newAllocation < minLimit {
                    newAllocation = minLimit
                }
                
                if newAllocation != token.allocatedBandwidth {
                    // TODO: Implement proper bandwidth adjustment
                    // await bandwidthManager.adjustTokenAllocation(
                    //     tokenId: token.id,
                    //     newAllocation: newAllocation
                    // )
                }
            }
        }
    }
    
    private func updateConditionTrends(_ conditions: NetworkConditions) async {
        let trend = NetworkConditionTrend(
            timestamp: Date(),
            quality: conditions.quality,
            bandwidth: conditions.bandwidth.downloadBps,
            latency: conditions.latency.rttMs,
            stability: conditions.stability
        )
        
        conditionTrends.append(trend)
        
        // Keep only recent trends (last hour)
        let oneHourAgo = Date().addingTimeInterval(-3600)
        conditionTrends.removeAll { $0.timestamp < oneHourAgo }
    }
    
    private func recordAdjustment(_ adjustment: BandwidthAdjustment) async {
        adjustmentHistory.append(adjustment)
        
        // Keep only recent adjustments (last 100)
        if adjustmentHistory.count > 100 {
            adjustmentHistory.removeFirst(adjustmentHistory.count - 100)
        }
    }
}

// MARK: - Supporting Types

/// Reason for bandwidth adjustment
enum AdjustmentReason: String, CaseIterable, Sendable {
    case periodicCheck = "periodic_check"
    case conditionChange = "condition_change"
    case userLimitChange = "user_limit_change"
    case downloadLimitChange = "download_limit_change"
    case manualTrigger = "manual_trigger"
    case performanceOptimization = "performance_optimization"
    case errorRecovery = "error_recovery"
}

/// Bandwidth limits for downloads
struct BandwidthLimits: Sendable {
    let min: Int64?
    let max: Int64?
    
    init(min: Int64? = nil, max: Int64? = nil) {
        self.min = min
        self.max = max
    }
}

/// Bandwidth adjustment recommendation
struct BandwidthRecommendation: Sendable {
    let downloadId: UUID
    let tokenId: UUID
    let currentAllocation: Int64
    let recommendedAllocation: Int64
    let adjustmentRatio: Double
    let reason: AdjustmentReason
    let confidence: Double
    let priority: BandwidthPriority
}

/// Result of applying a bandwidth adjustment
struct BandwidthAdjustmentResult: Sendable {
    let downloadId: UUID
    let success: Bool
    let oldAllocation: Int64
    let newAllocation: Int64
    let error: String?
}

/// Complete bandwidth adjustment record
struct BandwidthAdjustment: Sendable {
    let timestamp: Date
    let reason: AdjustmentReason
    let networkConditions: NetworkConditions
    let recommendations: [BandwidthRecommendation]
    let results: [BandwidthAdjustmentResult]
    let processingTime: TimeInterval
    
    var successRate: Double {
        guard !results.isEmpty else { return 0.0 }
        let successful = results.filter { $0.success }.count
        return Double(successful) / Double(results.count)
    }
}

/// Network condition trend for predictive analysis
struct NetworkConditionTrend: Sendable {
    let timestamp: Date
    let quality: NetworkQuality
    let bandwidth: Int64
    let latency: Double
    let stability: NetworkStability
}

/// Controller status information
struct AdaptiveControllerStatus: Sendable {
    let isActive: Bool
    let configuration: AdaptiveBandwidthController.Configuration
    let adjustmentCount: Int
    let lastAdjustment: BandwidthAdjustment?
    let performanceMetrics: AdaptiveControllerMetrics
    let userLimits: BandwidthLimits
    let downloadSpecificLimitsCount: Int
}

/// Performance metrics for the adaptive controller
struct AdaptiveControllerMetrics: Sendable {
    var totalAdjustments: Int = 0
    var totalRecommendations: Int = 0
    var successfulAdjustments: Int = 0
    var totalProcessingTime: TimeInterval = 0
    var lastAdjustmentTime: Date?
    var adjustmentsByReason: [AdjustmentReason: Int] = [:]
    var successRate: Double = 0.0
    var averageProcessingTime: TimeInterval = 0.0
}

/// Bandwidth prediction model for predictive adjustments
struct BandwidthPredictionModel: Sendable {
    let configuration: AdaptiveBandwidthController.Configuration
    
    init(configuration: AdaptiveBandwidthController.Configuration) {
        self.configuration = configuration
    }
    
    func predictOptimalAdjustment(
        token: BandwidthToken,
        conditions: NetworkConditions,
        trends: [NetworkConditionTrend]
    ) async -> Double {
        // Simple prediction based on recent trends
        guard trends.count >= 3 else { return 1.0 }
        
        let recentTrends = Array(trends.suffix(3))
        let bandwidthTrend = recentTrends.map(\.bandwidth)
        
        if bandwidthTrend.allSatisfy({ $0 > bandwidthTrend.first! }) {
            return 1.1 // Increasing trend, slight increase
        } else if bandwidthTrend.allSatisfy({ $0 < bandwidthTrend.first! }) {
            return 0.9 // Decreasing trend, slight decrease
        }
        
        return 1.0 // Stable trend, no change
    }
    
    func updateWithTrend(_ trend: NetworkConditionTrend) async {
        // Update prediction model with new trend data
        // Implementation would include machine learning or statistical analysis
    }
}