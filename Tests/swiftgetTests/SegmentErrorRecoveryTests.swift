import XCTest
import Foundation
import Logging
@testable import swiftget

final class SegmentErrorRecoveryTests: XCTestCase {
    
    var logger: Logger!
    var errorRecovery: SegmentErrorRecovery!
    
    override func setUp() async throws {
        try await super.setUp()
        logger = Logger(label: "test-error-recovery")
        logger.logLevel = .error // Reduce noise in tests
        errorRecovery = SegmentErrorRecovery(logger: logger)
    }
    
    // MARK: - SegmentErrorType Tests
    
    func testSegmentErrorTypeRetryability() {
        XCTAssertTrue(SegmentErrorType.networkTimeout.isRetryable)
        XCTAssertTrue(SegmentErrorType.connectionLost.isRetryable)
        XCTAssertTrue(SegmentErrorType.serverError.isRetryable)
        XCTAssertTrue(SegmentErrorType.rateLimited.isRetryable)
        XCTAssertTrue(SegmentErrorType.partialContentError.isRetryable)
        XCTAssertTrue(SegmentErrorType.corruptedData.isRetryable)
        XCTAssertFalse(SegmentErrorType.diskSpaceError.isRetryable)
        XCTAssertFalse(SegmentErrorType.unknownError.isRetryable)
    }
    
    func testSegmentErrorTypeRetryDelays() {
        XCTAssertEqual(SegmentErrorType.networkTimeout.baseRetryDelay, 1.0)
        XCTAssertEqual(SegmentErrorType.connectionLost.baseRetryDelay, 1.0)
        XCTAssertEqual(SegmentErrorType.serverError.baseRetryDelay, 2.0)
        XCTAssertEqual(SegmentErrorType.rateLimited.baseRetryDelay, 5.0)
        XCTAssertEqual(SegmentErrorType.partialContentError.baseRetryDelay, 0.5)
        XCTAssertEqual(SegmentErrorType.corruptedData.baseRetryDelay, 0.5)
        XCTAssertEqual(SegmentErrorType.diskSpaceError.baseRetryDelay, 0.0)
        XCTAssertEqual(SegmentErrorType.unknownError.baseRetryDelay, 0.0)
    }
    
    func testSegmentErrorTypeMaxRetries() {
        XCTAssertEqual(SegmentErrorType.networkTimeout.maxRetryAttempts, 5)
        XCTAssertEqual(SegmentErrorType.connectionLost.maxRetryAttempts, 5)
        XCTAssertEqual(SegmentErrorType.serverError.maxRetryAttempts, 3)
        XCTAssertEqual(SegmentErrorType.rateLimited.maxRetryAttempts, 2)
        XCTAssertEqual(SegmentErrorType.partialContentError.maxRetryAttempts, 3)
        XCTAssertEqual(SegmentErrorType.corruptedData.maxRetryAttempts, 3)
        XCTAssertEqual(SegmentErrorType.diskSpaceError.maxRetryAttempts, 0)
        XCTAssertEqual(SegmentErrorType.unknownError.maxRetryAttempts, 0)
    }
    
    // MARK: - SegmentError Tests
    
    func testSegmentErrorCreation() {
        let underlyingError = URLError(.timedOut)
        let segmentError = SegmentError(
            segmentIndex: 1,
            errorType: .networkTimeout,
            underlyingError: underlyingError,
            attemptNumber: 2,
            bytesTransferred: 1024
        )
        
        XCTAssertEqual(segmentError.segmentIndex, 1)
        XCTAssertEqual(segmentError.errorType, .networkTimeout)
        XCTAssertEqual(segmentError.attemptNumber, 2)
        XCTAssertEqual(segmentError.bytesTransferred, 1024)
        XCTAssertNotNil(segmentError.underlyingError)
        XCTAssertTrue(segmentError.localizedDescription.contains("Segment 1"))
        XCTAssertTrue(segmentError.localizedDescription.contains("network_timeout"))
    }
    
    // MARK: - SegmentRetryState Tests
    
    func testSegmentRetryStateInitialization() {
        let state = SegmentRetryState(segmentIndex: 0)
        
        XCTAssertEqual(state.segmentIndex, 0)
        XCTAssertEqual(state.attemptCount, 0)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.totalBytesTransferred, 0)
        XCTAssertEqual(state.backoffMultiplier, 1.0)
        XCTAssertFalse(state.isRedistributed)
        XCTAssertTrue(state.redistributionTargets.isEmpty)
        XCTAssertTrue(state.shouldRetry)
        XCTAssertEqual(state.nextRetryDelay, 0)
    }
    
    func testSegmentRetryStateFailureRecording() {
        var state = SegmentRetryState(segmentIndex: 0)
        let error = SegmentError(
            segmentIndex: 0,
            errorType: .networkTimeout,
            attemptNumber: 1,
            bytesTransferred: 500
        )
        
        state.recordFailure(error)
        
        XCTAssertEqual(state.attemptCount, 1)
        XCTAssertNotNil(state.lastError)
        XCTAssertEqual(state.totalBytesTransferred, 500)
        XCTAssertEqual(state.backoffMultiplier, 1.5)
        XCTAssertTrue(state.shouldRetry) // network timeout is retryable
        XCTAssertEqual(state.nextRetryDelay, 1.5) // 1.0 * 1.5
    }
    
    func testSegmentRetryStateRedistribution() {
        var state = SegmentRetryState(segmentIndex: 0)
        
        state.resetForRedistribution()
        
        XCTAssertEqual(state.attemptCount, 0)
        XCTAssertEqual(state.backoffMultiplier, 1.0)
        XCTAssertTrue(state.isRedistributed)
    }
    
    func testSegmentRetryStateBackoffCapping() {
        var state = SegmentRetryState(segmentIndex: 0)
        let error = SegmentError(segmentIndex: 0, errorType: .networkTimeout)
        
        // Record multiple failures to test backoff capping
        for _ in 0..<10 {
            state.recordFailure(error)
        }
        
        XCTAssertLessThanOrEqual(state.backoffMultiplier, 8.0) // Should be capped at 8x
    }
    
    // MARK: - ErrorRecoveryConfig Tests
    
    func testErrorRecoveryConfigDefaults() {
        let config = ErrorRecoveryConfig.default
        
        XCTAssertEqual(config.maxTotalRetries, 15)
        XCTAssertEqual(config.maxRedistributions, 3)
        XCTAssertEqual(config.fallbackThreshold, 0.5)
        XCTAssertEqual(config.redistributionSizeThreshold, 1_048_576)
        XCTAssertTrue(config.enableFallback)
    }
    
    func testErrorRecoveryConfigVariants() {
        let aggressive = ErrorRecoveryConfig.aggressive
        XCTAssertEqual(aggressive.maxTotalRetries, 25)
        XCTAssertEqual(aggressive.maxRedistributions, 5)
        XCTAssertEqual(aggressive.fallbackThreshold, 0.7)
        
        let conservative = ErrorRecoveryConfig.conservative
        XCTAssertEqual(conservative.maxTotalRetries, 5)
        XCTAssertEqual(conservative.maxRedistributions, 1)
        XCTAssertEqual(conservative.fallbackThreshold, 0.3)
    }
    
    // MARK: - SegmentErrorRecovery Tests
    
    func testErrorRecoveryInitialization() async {
        let segments = [
            SegmentRange(index: 0, start: 0, end: 499),
            SegmentRange(index: 1, start: 500, end: 999)
        ]
        
        await errorRecovery.initializeSegments(segments)
        
        let stats = await errorRecovery.getRecoveryStatistics()
        XCTAssertEqual(stats.activeSegmentCount, 2)
        XCTAssertEqual(stats.totalRetries, 0)
        XCTAssertEqual(stats.totalRedistributions, 0)
    }
    
    func testErrorClassificationURLError() async {
        let urlError = URLError(.timedOut)
        let segmentError = await errorRecovery.classifyError(
            urlError,
            segmentIndex: 0,
            attemptNumber: 1,
            bytesTransferred: 0
        )
        
        XCTAssertEqual(segmentError.errorType, .networkTimeout)
        XCTAssertEqual(segmentError.segmentIndex, 0)
        XCTAssertEqual(segmentError.attemptNumber, 1)
    }
    
    func testErrorClassificationDownloadError() async {
        let downloadError = DownloadError.connectionFailed(underlying: URLError(.networkConnectionLost))
        let segmentError = await errorRecovery.classifyError(
            downloadError,
            segmentIndex: 1,
            attemptNumber: 2,
            bytesTransferred: 1024
        )
        
        XCTAssertEqual(segmentError.errorType, .connectionLost)
        XCTAssertEqual(segmentError.segmentIndex, 1)
        XCTAssertEqual(segmentError.bytesTransferred, 1024)
    }
    
    func testErrorClassificationUnknownError() async {
        struct CustomError: Error {}
        let customError = CustomError()
        
        let segmentError = await errorRecovery.classifyError(
            customError,
            segmentIndex: 0,
            attemptNumber: 1,
            bytesTransferred: 0
        )
        
        XCTAssertEqual(segmentError.errorType, .unknownError)
    }
    
    // MARK: - Recovery Strategy Tests
    
    func testHandleSegmentFailureRetry() async {
        let segments = [SegmentRange(index: 0, start: 0, end: 999)]
        await errorRecovery.initializeSegments(segments)
        
        let segmentError = SegmentError(
            segmentIndex: 0,
            errorType: .networkTimeout,
            attemptNumber: 1
        )
        
        let strategy = await errorRecovery.handleSegmentFailure(segmentError)
        XCTAssertEqual(strategy, .retry)
        
        let stats = await errorRecovery.getRecoveryStatistics()
        XCTAssertEqual(stats.totalRetries, 1)
    }
    
    func testHandleSegmentFailureAbortAfterMaxRetries() async {
        let config = ErrorRecoveryConfig(
            maxTotalRetries: 2,
            maxRedistributions: 3,
            fallbackThreshold: 0.5,
            redistributionSizeThreshold: 1_048_576,
            enableFallback: true
        )
        let recovery = SegmentErrorRecovery(logger: logger, config: config)
        
        let segments = [SegmentRange(index: 0, start: 0, end: 999)]
        await recovery.initializeSegments(segments)
        
        // Exceed max retries
        for _ in 0..<3 {
            let segmentError = SegmentError(
                segmentIndex: 0,
                errorType: .networkTimeout,
                attemptNumber: 1
            )
            _ = await recovery.handleSegmentFailure(segmentError)
        }
        
        let segmentError = SegmentError(
            segmentIndex: 0,
            errorType: .networkTimeout,
            attemptNumber: 1
        )
        let strategy = await recovery.handleSegmentFailure(segmentError)
        XCTAssertEqual(strategy, .abort)
    }
    
    func testHandleSegmentFailureFallback() async {
        let config = ErrorRecoveryConfig(
            maxTotalRetries: 10,
            maxRedistributions: 0, // Disable redistribution
            fallbackThreshold: 0.4, // 40% failure threshold
            redistributionSizeThreshold: 1_048_576,
            enableFallback: true
        )
        let recovery = SegmentErrorRecovery(logger: logger, config: config)
        
        let segments = [
            SegmentRange(index: 0, start: 0, end: 249),
            SegmentRange(index: 1, start: 250, end: 499),
            SegmentRange(index: 2, start: 500, end: 749),
            SegmentRange(index: 3, start: 750, end: 999)
        ]
        await recovery.initializeSegments(segments)
        
        // Fail 2 out of 4 segments (50% > 40% threshold)
        for segmentIndex in [0, 1] {
            for _ in 0..<5 { // Exhaust retries
                let segmentError = SegmentError(
                    segmentIndex: segmentIndex,
                    errorType: .networkTimeout,
                    attemptNumber: 5
                )
                _ = await recovery.handleSegmentFailure(segmentError)
            }
        }
        
        // The next failure should trigger fallback
        let segmentError = SegmentError(
            segmentIndex: 0,
            errorType: .diskSpaceError, // Non-retryable
            attemptNumber: 1
        )
        let strategy = await recovery.handleSegmentFailure(segmentError)
        XCTAssertEqual(strategy, .fallback)
    }
    
    // MARK: - Redistribution Tests
    
    func testSegmentRedistribution() async {
        let segments = [
            SegmentRange(index: 0, start: 0, end: 499),
            SegmentRange(index: 1, start: 500, end: 999),
            SegmentRange(index: 2, start: 1000, end: 1499)
        ]
        await errorRecovery.initializeSegments(segments)
        
        let newSegments = await errorRecovery.redistributeSegment(
            0,
            amongSegments: [1, 2]
        )
        
        XCTAssertFalse(newSegments.isEmpty)
        XCTAssertLessThanOrEqual(newSegments.count, 2) // Should distribute among available segments
        
        // Check that new segments have negative indices
        for segment in newSegments {
            XCTAssertLessThan(segment.index, 0)
        }
        
        let stats = await errorRecovery.getRecoveryStatistics()
        XCTAssertEqual(stats.totalRedistributions, 1)
    }
    
    func testRedistributionLimits() async {
        let config = ErrorRecoveryConfig(
            maxTotalRetries: 10,
            maxRedistributions: 1,
            fallbackThreshold: 0.5,
            redistributionSizeThreshold: 1_048_576,
            enableFallback: true
        )
        let recovery = SegmentErrorRecovery(logger: logger, config: config)
        
        let segments = [
            SegmentRange(index: 0, start: 0, end: 1_048_575), // 1MB - 1 byte
            SegmentRange(index: 1, start: 1_048_576, end: 2_097_151)
        ]
        await recovery.initializeSegments(segments)
        
        // First redistribution should work
        let firstRedistribution = await recovery.redistributeSegment(0, amongSegments: [1])
        XCTAssertFalse(firstRedistribution.isEmpty)
        
        // Second redistribution should fail due to limits
        let secondRedistribution = await recovery.redistributeSegment(1, amongSegments: [])
        XCTAssertTrue(secondRedistribution.isEmpty)
    }
    
    // MARK: - Recovery Statistics Tests
    
    func testRecoveryStatistics() async {
        let segments = [
            SegmentRange(index: 0, start: 0, end: 499),
            SegmentRange(index: 1, start: 500, end: 999)
        ]
        await errorRecovery.initializeSegments(segments)
        
        // Create some failures and retries
        let segmentError1 = SegmentError(segmentIndex: 0, errorType: .networkTimeout)
        let segmentError2 = SegmentError(segmentIndex: 1, errorType: .serverError)
        
        await errorRecovery.handleSegmentFailure(segmentError1)
        await errorRecovery.handleSegmentFailure(segmentError2)
        
        let stats = await errorRecovery.getRecoveryStatistics()
        
        XCTAssertEqual(stats.totalRetries, 2)
        XCTAssertEqual(stats.retriedSegmentCount, 2)
        XCTAssertGreaterThanOrEqual(stats.activeSegmentCount, 0)
        
        // Test calculated properties
        XCTAssertGreaterThanOrEqual(stats.failureRate, 0.0)
        XCTAssertLessThanOrEqual(stats.failureRate, 1.0)
        XCTAssertGreaterThanOrEqual(stats.redistributionRate, 0.0)
        XCTAssertLessThanOrEqual(stats.redistributionRate, 1.0)
    }
    
    // MARK: - Performance Tests
    
    func testErrorRecoveryPerformance() async {
        let segments = Array(0..<10).map { index in
            SegmentRange(index: index, start: Int64(index * 100), end: Int64((index + 1) * 100 - 1))
        }
        
        measure {
            let expectation = XCTestExpectation(description: "Error recovery performance test")
            
            Task {
                await errorRecovery.initializeSegments(segments)
                
                for i in 0..<100 {
                    let segmentError = SegmentError(
                        segmentIndex: i % 10,
                        errorType: .networkTimeout,
                        attemptNumber: 1
                    )
                    _ = await errorRecovery.handleSegmentFailure(segmentError)
                }
                
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 5.0)
        }
    }
    
    // MARK: - Edge Cases
    
    func testHandleUnknownSegmentIndex() async {
        let segments = [SegmentRange(index: 0, start: 0, end: 999)]
        await errorRecovery.initializeSegments(segments)
        
        let segmentError = SegmentError(
            segmentIndex: 999, // Unknown segment
            errorType: .networkTimeout
        )
        
        let strategy = await errorRecovery.handleSegmentFailure(segmentError)
        XCTAssertEqual(strategy, .abort)
    }
    
    func testRedistributionWithNoActiveSegments() async {
        let segments = [SegmentRange(index: 0, start: 0, end: 999)]
        await errorRecovery.initializeSegments(segments)
        
        let newSegments = await errorRecovery.redistributeSegment(0, amongSegments: [])
        XCTAssertTrue(newSegments.isEmpty)
    }
    
    func testSegmentTooSmallForRedistribution() async {
        let config = ErrorRecoveryConfig(
            maxTotalRetries: 10,
            maxRedistributions: 3,
            fallbackThreshold: 0.5,
            redistributionSizeThreshold: 1_000_000, // 1MB threshold
            enableFallback: true
        )
        let recovery = SegmentErrorRecovery(logger: logger, config: config)
        
        let segments = [
            SegmentRange(index: 0, start: 0, end: 999), // Only 1000 bytes, below threshold
            SegmentRange(index: 1, start: 1000, end: 1999)
        ]
        await recovery.initializeSegments(segments)
        
        let newSegments = await recovery.redistributeSegment(0, amongSegments: [1])
        XCTAssertTrue(newSegments.isEmpty) // Should fail due to size threshold
    }
}