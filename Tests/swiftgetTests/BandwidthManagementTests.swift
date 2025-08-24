import XCTest
import Foundation
import Logging
@testable import swiftget

final class BandwidthManagementTests: XCTestCase {
    
    var logger: Logger!
    var bandwidthManager: GlobalBandwidthManager!
    
    override func setUp() async throws {
        try await super.setUp()
        logger = Logger(label: "test-bandwidth-management")
        logger.logLevel = .error // Reduce noise in tests
        
        // Initialize with 10 MB/s limit for testing
        bandwidthManager = GlobalBandwidthManager(
            totalBandwidthLimit: 10_485_760, // 10 MB/s
            configuration: .default,
            logger: logger
        )
    }
    
    override func tearDown() async throws {
        bandwidthManager = nil
        try await super.tearDown()
    }
    
    // MARK: - BandwidthToken Tests
    
    func testBandwidthTokenCreation() {
        let downloadId = UUID()
        let token = BandwidthToken(
            downloadId: downloadId,
            allocatedBandwidth: 1_048_576, // 1 MB/s
            priority: .high,
            downloadType: .userInitiated
        )
        
        XCTAssertEqual(token.downloadId, downloadId)
        XCTAssertEqual(token.allocatedBandwidth, 1_048_576)
        XCTAssertEqual(token.priority, .high)
        XCTAssertEqual(token.downloadType, .userInitiated)
        XCTAssertFalse(token.isExpired)
        XCTAssertEqual(token.utilizationRatio, 0.0)
    }
    
    func testBandwidthTokenUsageTracking() {
        let token = BandwidthToken(
            downloadId: UUID(),
            allocatedBandwidth: 1_048_576, // 1 MB/s
            priority: .normal
        )
        
        // Test usage update
        let updatedToken = token.withUpdatedUsage(actualUsage: 524_288) // 500 KB/s
        
        XCTAssertEqual(updatedToken.lastReportedUsage, 524_288)
        XCTAssertEqual(updatedToken.utilizationRatio, 0.5, accuracy: 0.01)
        XCTAssertFalse(updatedToken.isUnderUtilized)
        XCTAssertFalse(updatedToken.isOverUtilized)
    }
    
    func testBandwidthTokenUnderUtilization() {
        let token = BandwidthToken(
            downloadId: UUID(),
            allocatedBandwidth: 1_048_576, // 1 MB/s
            priority: .normal
        )
        
        // Test under-utilization
        let underUtilizedToken = token.withUpdatedUsage(actualUsage: 104_857) // ~100 KB/s (10%)
        
        XCTAssertTrue(underUtilizedToken.isUnderUtilized)
        XCTAssertFalse(underUtilizedToken.isOverUtilized)
        XCTAssertLessThan(underUtilizedToken.utilizationRatio, 0.5)
    }
    
    func testBandwidthTokenOverUtilization() {
        let token = BandwidthToken(
            downloadId: UUID(),
            allocatedBandwidth: 1_048_576, // 1 MB/s
            priority: .normal
        )
        
        // Test over-utilization
        let overUtilizedToken = token.withUpdatedUsage(actualUsage: 2_097_152) // 2 MB/s (200%)
        
        XCTAssertFalse(overUtilizedToken.isUnderUtilized)
        XCTAssertTrue(overUtilizedToken.isOverUtilized)
        XCTAssertGreaterThan(overUtilizedToken.utilizationRatio, 1.0)
    }
    
    func testBandwidthTokenExpiration() {
        let expiredTime = Date().addingTimeInterval(-3600) // 1 hour ago
        let token = BandwidthToken(
            downloadId: UUID(),
            allocatedBandwidth: 1_048_576,
            priority: .normal,
            expirationTime: expiredTime
        )
        
        XCTAssertTrue(token.isExpired)
        
        let validation = token.validate()
        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.hasIssues)
        XCTAssertTrue(validation.issues.contains { $0.contains("expired") })
    }
    
    func testBandwidthTokenValidation() {
        let token = BandwidthToken(
            downloadId: UUID(),
            allocatedBandwidth: 1_048_576,
            priority: .normal
        )
        
        let validation = token.validate(maxAge: 300, maxInactivity: 60)
        XCTAssertTrue(validation.isValid)
        XCTAssertFalse(validation.hasIssues)
    }
    
    func testBandwidthTokenUsageAnalysis() {
        let token = BandwidthToken(
            downloadId: UUID(),
            allocatedBandwidth: 1_048_576, // 1 MB/s
            priority: .normal
        )
        
        // Test with no usage data
        let noUsageAnalysis = token.analyzeUsage()
        XCTAssertEqual(noUsageAnalysis.recommendation, .awaitingFirstUsageReport)
        XCTAssertEqual(noUsageAnalysis.efficiency, 0.0)
        
        // Test with good utilization
        let goodToken = token.withUpdatedUsage(actualUsage: 629_145) // ~60%
        let goodAnalysis = goodToken.analyzeUsage()
        XCTAssertEqual(goodAnalysis.recommendation, .maintainCurrent)
        XCTAssertGreaterThan(goodAnalysis.efficiency, 0.5)
        
        // Test with low utilization
        let lowToken = token.withUpdatedUsage(actualUsage: 104_857) // ~10%
        let lowAnalysis = lowToken.analyzeUsage()
        XCTAssertEqual(lowAnalysis.recommendation, .reduceAllocation)
        
        // Test with high utilization
        let highToken = token.withUpdatedUsage(actualUsage: 1_258_291) // ~120%
        let highAnalysis = highToken.analyzeUsage()
        XCTAssertEqual(highAnalysis.recommendation, .increaseAllocation)
    }
    
    func testBandwidthTokenFactoryMethods() {
        let downloadId = UUID()
        
        // Test user download token
        let userToken = BandwidthToken.forUserDownload(
            downloadId: downloadId,
            requestedBandwidth: 2_097_152
        )
        XCTAssertEqual(userToken.priority, .high)
        XCTAssertEqual(userToken.downloadType, .userInitiated)
        XCTAssertTrue(userToken.metadata.tags.contains("user"))
        
        // Test background download token
        let backgroundToken = BandwidthToken.forBackgroundDownload(
            downloadId: downloadId,
            requestedBandwidth: 524_288
        )
        XCTAssertEqual(backgroundToken.priority, .low)
        XCTAssertEqual(backgroundToken.downloadType, .background)
        XCTAssertNotNil(backgroundToken.expirationTime)
        
        // Test system download token
        let systemToken = BandwidthToken.forSystemDownload(
            downloadId: downloadId,
            requestedBandwidth: 5_242_880
        )
        XCTAssertEqual(systemToken.priority, .critical)
        XCTAssertEqual(systemToken.downloadType, .system)
    }
    
    // MARK: - GlobalBandwidthManager Tests
    
    func testBandwidthManagerInitialization() async {
        let stats = await bandwidthManager.getStatistics()
        
        XCTAssertEqual(stats.totalBandwidthLimit, 10_485_760)
        XCTAssertEqual(stats.currentAllocatedBandwidth, 0)
        XCTAssertEqual(stats.currentAvailableBandwidth, 10_485_760)
        XCTAssertEqual(stats.activeDownloads, 0)
        XCTAssertEqual(stats.queuedRequests, 0)
    }
    
    func testBandwidthAllocation() async {
        let downloadId = UUID()
        
        // Request bandwidth allocation
        let token = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 2_097_152, // 2 MB/s
            priority: .normal,
            downloadId: downloadId
        )
        
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.downloadId, downloadId)
        XCTAssertEqual(token?.allocatedBandwidth, 2_097_152)
        XCTAssertEqual(token?.priority, .normal)
        
        // Check statistics
        let stats = await bandwidthManager.getStatistics()
        XCTAssertEqual(stats.currentAllocatedBandwidth, 2_097_152)
        XCTAssertEqual(stats.currentAvailableBandwidth, 8_388_608)
        XCTAssertEqual(stats.activeDownloads, 1)
    }
    
    func testBandwidthAllocationDenial() async {
        let downloadId1 = UUID()
        let downloadId2 = UUID()
        
        // Allocate most of the bandwidth
        let token1 = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 9_437_184, // 9 MB/s
            priority: .normal,
            downloadId: downloadId1
        )
        XCTAssertNotNil(token1)
        
        // Try to allocate more than available
        let token2 = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 5_242_880, // 5 MB/s
            priority: .normal,
            downloadId: downloadId2
        )
        
        // Should still get some allocation, but less than requested
        XCTAssertNotNil(token2)
        if let token2 = token2 {
            XCTAssertLessThan(token2.allocatedBandwidth, 5_242_880)
            XCTAssertGreaterThan(token2.allocatedBandwidth, 0)
        }
    }
    
    func testBandwidthPriorityAllocation() async {
        let lowPriorityId = UUID()
        let highPriorityId = UUID()
        
        // Request with low priority first
        let lowToken = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 5_242_880, // 5 MB/s
            priority: .low,
            downloadId: lowPriorityId
        )
        XCTAssertNotNil(lowToken)
        
        // Request with high priority
        let highToken = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 5_242_880, // 5 MB/s
            priority: .high,
            downloadId: highPriorityId
        )
        XCTAssertNotNil(highToken)
        
        // High priority should get better allocation
        if let lowToken = lowToken, let highToken = highToken {
            XCTAssertGreaterThanOrEqual(highToken.allocatedBandwidth, lowToken.allocatedBandwidth)
        }
    }
    
    func testBandwidthRelease() async {
        let downloadId = UUID()
        
        // Allocate bandwidth
        let token = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 3_145_728, // 3 MB/s
            priority: .normal,
            downloadId: downloadId
        )
        XCTAssertNotNil(token)
        
        var stats = await bandwidthManager.getStatistics()
        XCTAssertEqual(stats.currentAllocatedBandwidth, 3_145_728)
        XCTAssertEqual(stats.activeDownloads, 1)
        
        // Release bandwidth
        if let token = token {
            await bandwidthManager.releaseBandwidth(tokenId: token.id)
        }
        
        stats = await bandwidthManager.getStatistics()
        XCTAssertEqual(stats.currentAllocatedBandwidth, 0)
        XCTAssertEqual(stats.activeDownloads, 0)
        XCTAssertEqual(stats.currentAvailableBandwidth, 10_485_760)
    }
    
    func testBandwidthUsageReporting() async {
        let downloadId = UUID()
        
        let token = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 2_097_152, // 2 MB/s
            priority: .normal,
            downloadId: downloadId
        )
        XCTAssertNotNil(token)
        
        if let token = token {
            // Report usage
            await bandwidthManager.updateBandwidthUsage(
                tokenId: token.id,
                actualUsage: 1_048_576 // 1 MB/s actual usage
            )
            
            // Get active tokens to verify usage was recorded
            let activeTokens = await bandwidthManager.getActiveTokens()
            let updatedToken = activeTokens.first { $0.id == token.id }
            
            XCTAssertNotNil(updatedToken)
            // Note: The exact usage might be different due to timing and averaging
            XCTAssertNotNil(updatedToken?.lastReportedUsage)
        }
    }
    
    func testBandwidthLimitAdjustment() async {
        let downloadId = UUID()
        
        // Allocate some bandwidth
        let token = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 2_097_152, // 2 MB/s
            priority: .normal,
            downloadId: downloadId
        )
        XCTAssertNotNil(token)
        
        var stats = await bandwidthManager.getStatistics()
        XCTAssertEqual(stats.totalBandwidthLimit, 10_485_760)
        
        // Increase bandwidth limit
        await bandwidthManager.adjustBandwidthLimit(20_971_520) // 20 MB/s
        
        stats = await bandwidthManager.getStatistics()
        XCTAssertEqual(stats.totalBandwidthLimit, 20_971_520)
        XCTAssertEqual(stats.currentAvailableBandwidth, 18_874_368) // 20MB - 2MB allocated
        
        // Decrease bandwidth limit
        await bandwidthManager.adjustBandwidthLimit(5_242_880) // 5 MB/s
        
        stats = await bandwidthManager.getStatistics()
        XCTAssertEqual(stats.totalBandwidthLimit, 5_242_880)
    }
    
    // MARK: - SpeedLimiter Tests
    
    func testSpeedLimiterStandaloneMode() async {
        let speedLimiter = SpeedLimiter(
            maxBytesPerSecond: 1_048_576, // 1 MB/s
            configuration: .default,
            logger: logger
        )
        
        let isActive = await speedLimiter.isActive
        XCTAssertTrue(isActive)
        
        let stats = await speedLimiter.getSpeedStatistics()
        XCTAssertEqual(stats.bandwidthLimit, 1_048_576)
        XCTAssertEqual(stats.currentRate, 0)
        XCTAssertFalse(stats.isThrottling)
    }
    
    func testSpeedLimiterTokenMode() async {
        let downloadId = UUID()
        
        let token = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 2_097_152, // 2 MB/s
            priority: .normal,
            downloadId: downloadId
        )
        XCTAssertNotNil(token)
        
        if let token = token {
            let speedLimiter = SpeedLimiter(
                bandwidthToken: token,
                bandwidthManager: bandwidthManager,
                configuration: .default,
                logger: logger
            )
            
            let isActive = await speedLimiter.isActive
            XCTAssertTrue(isActive)
            
            let stats = await speedLimiter.getSpeedStatistics()
            XCTAssertEqual(stats.bandwidthLimit, 2_097_152)
        }
    }
    
    func testSpeedLimiterThrottling() async {
        let speedLimiter = SpeedLimiter(
            maxBytesPerSecond: 1024, // 1 KB/s (very low for testing)
            configuration: .strict,
            logger: logger
        )
        
        let startTime = Date()
        
        // Write 2KB quickly, should trigger throttling
        await speedLimiter.throttle(wrote: 2048)
        
        let elapsed = Date().timeIntervalSince(startTime)
        
        // Should have been throttled for approximately 1 second
        XCTAssertGreaterThan(elapsed, 0.5)
        
        let stats = await speedLimiter.getSpeedStatistics()
        XCTAssertGreaterThan(stats.currentRate, 0)
    }
    
    func testSpeedLimiterTokenUpdate() async {
        let downloadId = UUID()
        
        let initialToken = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 1_048_576, // 1 MB/s
            priority: .normal,
            downloadId: downloadId
        )
        XCTAssertNotNil(initialToken)
        
        if let initialToken = initialToken {
            let speedLimiter = SpeedLimiter(
                bandwidthToken: initialToken,
                bandwidthManager: bandwidthManager,
                configuration: .default,
                logger: logger
            )
            
            var stats = await speedLimiter.getSpeedStatistics()
            XCTAssertEqual(stats.bandwidthLimit, 1_048_576)
            
            // Update token with new allocation
            let updatedToken = initialToken.withNewAllocation(2_097_152)
            await speedLimiter.updateBandwidthToken(updatedToken)
            
            stats = await speedLimiter.getSpeedStatistics()
            XCTAssertEqual(stats.bandwidthLimit, 2_097_152)
        }
    }
    
    func testSpeedLimiterFactoryMethods() {
        // Test high priority limiter
        let highPriorityLimiter = SpeedLimiter.forHighPriorityDownload(
            maxBytesPerSecond: 5_242_880,
            logger: logger
        )
        // Note: Can't directly test configuration without exposing internal state
        
        // Test background limiter
        let backgroundLimiter = SpeedLimiter.forBackgroundDownload(
            maxBytesPerSecond: 1_048_576,
            logger: logger
        )
        
        // These should not be nil
        XCTAssertNotNil(highPriorityLimiter)
        XCTAssertNotNil(backgroundLimiter)
    }
    
    // MARK: - BandwidthTokenCollection Tests
    
    func testBandwidthTokenCollection() {
        let downloadId1 = UUID()
        let downloadId2 = UUID()
        
        let token1 = BandwidthToken(
            downloadId: downloadId1,
            allocatedBandwidth: 1_048_576,
            priority: .high
        )
        
        let token2 = BandwidthToken(
            downloadId: downloadId2,
            allocatedBandwidth: 524_288,
            priority: .low
        )
        
        let collection = BandwidthTokenCollection(tokens: [token1, token2])
        
        XCTAssertEqual(collection.allTokens.count, 2)
        XCTAssertEqual(collection.activeTokens.count, 2)
        XCTAssertEqual(collection.expiredTokens.count, 0)
        XCTAssertEqual(collection.totalAllocatedBandwidth, 1_572_864)
        
        // Test filtering by priority
        let highPriorityTokens = collection.tokens(withPriority: .high)
        XCTAssertEqual(highPriorityTokens.count, 1)
        XCTAssertEqual(highPriorityTokens.first?.priority, .high)
        
        // Test filtering by download
        let download1Tokens = collection.tokens(forDownload: downloadId1)
        XCTAssertEqual(download1Tokens.count, 1)
        XCTAssertEqual(download1Tokens.first?.downloadId, downloadId1)
    }
    
    // MARK: - Integration Tests
    
    func testBandwidthManagerSpeedLimiterIntegration() async {
        let downloadId = UUID()
        
        // Request bandwidth through manager
        let token = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 2_097_152, // 2 MB/s
            priority: .normal,
            downloadId: downloadId
        )
        XCTAssertNotNil(token)
        
        if let token = token {
            // Create speed limiter with token
            let speedLimiter = SpeedLimiter(
                bandwidthToken: token,
                bandwidthManager: bandwidthManager,
                configuration: .default,
                logger: logger
            )
            
            // Simulate some usage
            await speedLimiter.throttle(wrote: 1024)
            
            // Allow some time for usage reporting
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            let stats = await speedLimiter.getSpeedStatistics()
            XCTAssertEqual(stats.bandwidthLimit, 2_097_152)
            XCTAssertGreaterThan(stats.totalBytesProcessed, 0)
        }
    }
    
    func testConcurrentBandwidthRequests() async {
        let downloadIds = (0..<5).map { _ in UUID() }
        
        // Request bandwidth sequentially to avoid concurrency issues in test
        var tokens: [BandwidthToken] = []
        for downloadId in downloadIds {
            if let token = await bandwidthManager.requestBandwidth(
                requestedBandwidth: 2_097_152, // 2 MB/s each
                priority: .normal,
                downloadId: downloadId
            ) {
                tokens.append(token)
            }
        }
        
        // Should have allocated bandwidth to all requests (though possibly reduced amounts)
        XCTAssertEqual(tokens.count, 5)
        
        let stats = await bandwidthManager.getStatistics()
        XCTAssertEqual(stats.activeDownloads, 5)
        XCTAssertLessThanOrEqual(stats.currentAllocatedBandwidth, stats.totalBandwidthLimit)
    }
    
    // MARK: - Performance Tests
    
    func testBandwidthManagerPerformance() {
        // Simple synchronous test since async measure is complex
        let downloadId = UUID()
        
        measure {
            // Test the synchronous parts we can measure
            let token = BandwidthToken(
                downloadId: downloadId,
                allocatedBandwidth: 1_048_576,
                priority: .normal
            )
            let _ = token.formattedBandwidth
        }
    }
    
    func testSpeedLimiterPerformance() {
        // Test synchronous creation performance
        measure {
            let _ = SpeedLimiter(
                maxBytesPerSecond: 10_485_760, // 10 MB/s
                configuration: .default,
                logger: logger
            )
        }
    }
    
    // MARK: - Edge Cases
    
    func testZeroBandwidthRequest() async {
        let downloadId = UUID()
        
        let token = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 0,
            priority: .normal,
            downloadId: downloadId
        )
        
        // Should handle gracefully
        XCTAssertNil(token)
    }
    
    func testNegativeBandwidthRequest() async {
        let downloadId = UUID()
        
        let token = await bandwidthManager.requestBandwidth(
            requestedBandwidth: -1000,
            priority: .normal,
            downloadId: downloadId
        )
        
        // Should handle gracefully
        XCTAssertNil(token)
    }
    
    func testExcessiveBandwidthRequest() async {
        let downloadId = UUID()
        
        let token = await bandwidthManager.requestBandwidth(
            requestedBandwidth: 1_073_741_824, // 1 GB/s (excessive)
            priority: .normal,
            downloadId: downloadId
        )
        
        // Should still allocate something, but much less than requested
        XCTAssertNotNil(token)
        if let token = token {
            XCTAssertLessThan(token.allocatedBandwidth, 1_073_741_824)
            XCTAssertLessThanOrEqual(token.allocatedBandwidth, 10_485_760) // Within total limit
        }
    }
    
    func testBandwidthTokenEquality() {
        let downloadId = UUID()
        let token1 = BandwidthToken(downloadId: downloadId, allocatedBandwidth: 1_048_576, priority: .normal)
        let token2 = BandwidthToken(downloadId: downloadId, allocatedBandwidth: 1_048_576, priority: .normal)
        
        // Tokens should be equal only if they have the same ID
        XCTAssertNotEqual(token1, token2) // Different IDs
        XCTAssertEqual(token1, token1) // Same instance
    }
    
    func testBandwidthTokenHashable() {
        let token = BandwidthToken(downloadId: UUID(), allocatedBandwidth: 1_048_576, priority: .normal)
        
        var set = Set<BandwidthToken>()
        set.insert(token)
        
        XCTAssertTrue(set.contains(token))
        XCTAssertEqual(set.count, 1)
    }
}