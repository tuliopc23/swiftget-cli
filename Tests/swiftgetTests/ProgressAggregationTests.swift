import XCTest
import Foundation
import Logging
@testable import swiftget

final class ProgressAggregationTests: XCTestCase {
    
    var logger: Logger!
    
    override func setUp() {
        super.setUp()
        logger = Logger(label: "test-progress-aggregation")
        logger.logLevel = .error // Reduce noise in tests
    }
    
    // MARK: - SegmentProgress Tests
    
    func testSegmentProgressInitialization() {
        let segment = SegmentProgress(segmentIndex: 0, totalBytes: 1000)
        
        XCTAssertEqual(segment.segmentIndex, 0)
        XCTAssertEqual(segment.bytesDownloaded, 0)
        XCTAssertEqual(segment.totalBytes, 1000)
        XCTAssertEqual(segment.averageSpeed, 0.0)
        XCTAssertFalse(segment.isComplete)
        XCTAssertEqual(segment.progressPercentage, 0.0)
    }
    
    func testSegmentProgressUpdate() {
        var segment = SegmentProgress(segmentIndex: 0, totalBytes: 1000)
        
        segment.updateProgress(additionalBytes: 500)
        
        XCTAssertEqual(segment.bytesDownloaded, 500)
        XCTAssertEqual(segment.progressPercentage, 0.5, accuracy: 0.01)
        XCTAssertFalse(segment.isComplete)
        XCTAssertGreaterThan(segment.averageSpeed, 0)
    }
    
    func testSegmentProgressCompletion() {
        var segment = SegmentProgress(segmentIndex: 0, totalBytes: 1000)
        
        segment.updateProgress(additionalBytes: 1000)
        
        XCTAssertEqual(segment.bytesDownloaded, 1000)
        XCTAssertEqual(segment.progressPercentage, 1.0, accuracy: 0.01)
        XCTAssertTrue(segment.isComplete)
    }
    
    func testSegmentProgressETACalculation() {
        var segment = SegmentProgress(segmentIndex: 0, totalBytes: 1000)
        
        segment.updateProgress(additionalBytes: 500)
        
        XCTAssertNotNil(segment.estimatedTimeRemaining)
        if let eta = segment.estimatedTimeRemaining {
            XCTAssertGreaterThan(eta, 0)
        }
    }
    
    // MARK: - ConcurrentProgressAggregator Tests
    
    func testProgressAggregatorInitialization() async {
        let mockProgressReporter = MockProgressReporter()
        let segmentRanges = [
            SegmentRange(index: 0, start: 0, end: 499),
            SegmentRange(index: 1, start: 500, end: 999)
        ]
        
        let aggregator = ConcurrentProgressAggregator(
            totalBytes: 1000,
            progressReporter: mockProgressReporter,
            segmentRanges: segmentRanges,
            logger: logger
        )
        
        let stats = await aggregator.getDownloadStatistics()
        XCTAssertEqual(stats.totalBytes, 1000)
        XCTAssertEqual(stats.bytesDownloaded, 0)
        XCTAssertEqual(stats.segmentCount, 2)
        XCTAssertEqual(stats.completedSegments, 0)
        XCTAssertEqual(stats.activeSegments, 0)
    }
    
    func testProgressAggregatorSingleSegmentUpdate() async {
        let mockProgressReporter = MockProgressReporter()
        let segmentRanges = [
            SegmentRange(index: 0, start: 0, end: 999)
        ]
        
        let aggregator = ConcurrentProgressAggregator(
            totalBytes: 1000,
            progressReporter: mockProgressReporter,
            segmentRanges: segmentRanges,
            logger: logger
        )
        
        await aggregator.reportSegmentProgress(segmentIndex: 0, additionalBytes: 500)
        
        let stats = await aggregator.getDownloadStatistics()
        XCTAssertEqual(stats.bytesDownloaded, 500)
        XCTAssertEqual(stats.progressPercentage, 0.5, accuracy: 0.01)
        XCTAssertEqual(stats.activeSegments, 1)
        XCTAssertGreaterThan(stats.currentSpeed, 0)
    }
    
    func testProgressAggregatorMultiSegmentUpdates() async {
        let mockProgressReporter = MockProgressReporter()
        let segmentRanges = [
            SegmentRange(index: 0, start: 0, end: 499),
            SegmentRange(index: 1, start: 500, end: 999)
        ]
        
        let aggregator = ConcurrentProgressAggregator(
            totalBytes: 1000,
            progressReporter: mockProgressReporter,
            segmentRanges: segmentRanges,
            logger: logger
        )
        
        // Update both segments
        await aggregator.reportSegmentProgress(segmentIndex: 0, additionalBytes: 250)
        await aggregator.reportSegmentProgress(segmentIndex: 1, additionalBytes: 300)
        
        let stats = await aggregator.getDownloadStatistics()
        XCTAssertEqual(stats.bytesDownloaded, 550)
        XCTAssertEqual(stats.progressPercentage, 0.55, accuracy: 0.01)
        XCTAssertEqual(stats.activeSegments, 2)
        XCTAssertEqual(stats.completedSegments, 0)
    }
    
    func testProgressAggregatorSegmentCompletion() async {
        let mockProgressReporter = MockProgressReporter()
        let segmentRanges = [
            SegmentRange(index: 0, start: 0, end: 499),
            SegmentRange(index: 1, start: 500, end: 999)
        ]
        
        let aggregator = ConcurrentProgressAggregator(
            totalBytes: 1000,
            progressReporter: mockProgressReporter,
            segmentRanges: segmentRanges,
            logger: logger
        )
        
        // Complete first segment
        await aggregator.reportSegmentProgress(segmentIndex: 0, additionalBytes: 500)
        await aggregator.markSegmentComplete(segmentIndex: 0)
        
        let stats = await aggregator.getDownloadStatistics()
        XCTAssertEqual(stats.completedSegments, 1)
        XCTAssertEqual(stats.activeSegments, 0)
    }
    
    func testProgressAggregatorSegmentProgress() async {
        let mockProgressReporter = MockProgressReporter()
        let segmentRanges = [
            SegmentRange(index: 0, start: 0, end: 499),
            SegmentRange(index: 1, start: 500, end: 999)
        ]
        
        let aggregator = ConcurrentProgressAggregator(
            totalBytes: 1000,
            progressReporter: mockProgressReporter,
            segmentRanges: segmentRanges,
            logger: logger
        )
        
        await aggregator.reportSegmentProgress(segmentIndex: 0, additionalBytes: 250)
        await aggregator.reportSegmentProgress(segmentIndex: 1, additionalBytes: 300)
        
        let segmentProgress = await aggregator.getSegmentProgress()
        XCTAssertEqual(segmentProgress.count, 2)
        
        let segment0 = segmentProgress.first { $0.segmentIndex == 0 }
        let segment1 = segmentProgress.first { $0.segmentIndex == 1 }
        
        XCTAssertNotNil(segment0)
        XCTAssertNotNil(segment1)
        XCTAssertEqual(segment0?.bytesDownloaded, 250)
        XCTAssertEqual(segment1?.bytesDownloaded, 300)
    }
    
    // MARK: - Thread Safety Tests
    
    func testProgressAggregatorThreadSafety() async {
        let mockProgressReporter = MockProgressReporter()
        let segmentRanges = [
            SegmentRange(index: 0, start: 0, end: 249),
            SegmentRange(index: 1, start: 250, end: 499),
            SegmentRange(index: 2, start: 500, end: 749),
            SegmentRange(index: 3, start: 750, end: 999)
        ]
        
        let aggregator = ConcurrentProgressAggregator(
            totalBytes: 1000,
            progressReporter: mockProgressReporter,
            segmentRanges: segmentRanges,
            logger: logger
        )
        
        // Simulate concurrent updates from multiple segments
        await withTaskGroup(of: Void.self) { group in
            for segmentIndex in 0..<4 {
                group.addTask {
                    for _ in 0..<50 {
                        await aggregator.reportSegmentProgress(segmentIndex: segmentIndex, additionalBytes: 5)
                        try? await Task.sleep(nanoseconds: 1_000) // 1 microsecond
                    }
                }
            }
        }
        
        let stats = await aggregator.getDownloadStatistics()
        XCTAssertEqual(stats.bytesDownloaded, 1000) // 4 segments * 50 updates * 5 bytes
        XCTAssertEqual(stats.activeSegments, 4)
    }
    
    // MARK: - Performance Tests
    
    func testProgressAggregatorPerformance() async {
        let mockProgressReporter = MockProgressReporter()
        let segmentRanges = Array(0..<8).map { index in
            SegmentRange(index: index, start: Int64(index * 125), end: Int64((index + 1) * 125 - 1))
        }
        
        let aggregator = ConcurrentProgressAggregator(
            totalBytes: 1000,
            progressReporter: mockProgressReporter,
            segmentRanges: segmentRanges,
            logger: logger
        )
        
        measure {
            let expectation = XCTestExpectation(description: "Progress updates completed")
            
            Task {
                // Simulate rapid progress updates
                for _ in 0..<1000 {
                    await aggregator.reportSegmentProgress(segmentIndex: 0, additionalBytes: 1)
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 5.0)
        }
    }
    
    // MARK: - ProgressDisplayConfig Tests
    
    func testProgressDisplayConfigDefaults() {
        let defaultConfig = ProgressDisplayConfig.default
        
        XCTAssertEqual(defaultConfig.mode, .simple)
        XCTAssertFalse(defaultConfig.showSegments)
        XCTAssertEqual(defaultConfig.updateInterval, 0.1, accuracy: 0.01)
        XCTAssertEqual(defaultConfig.progressBarWidth, 30)
    }
    
    func testProgressDisplayConfigMultiConnection() {
        let multiConfig = ProgressDisplayConfig.multiConnection
        
        XCTAssertEqual(multiConfig.mode, .detailed)
        XCTAssertTrue(multiConfig.showSegments)
        XCTAssertEqual(multiConfig.updateInterval, 0.1, accuracy: 0.01)
        XCTAssertEqual(multiConfig.progressBarWidth, 40)
    }
    
    // MARK: - Integration Tests
    
    func testProgressAggregatorWithRealProgressReporter() async {
        let testURL = URL(string: "https://example.com/test.zip")!
        let progressReporter = ProgressReporter(
            url: testURL,
            quiet: true, // Quiet mode to avoid console output during tests
            totalBytes: 1000,
            config: .multiConnection
        )
        
        let segmentRanges = [
            SegmentRange(index: 0, start: 0, end: 499),
            SegmentRange(index: 1, start: 500, end: 999)
        ]
        
        let aggregator = ConcurrentProgressAggregator(
            totalBytes: 1000,
            progressReporter: progressReporter,
            segmentRanges: segmentRanges,
            logger: logger
        )
        
        // Simulate download progress
        await aggregator.reportSegmentProgress(segmentIndex: 0, additionalBytes: 500)
        await aggregator.reportSegmentProgress(segmentIndex: 1, additionalBytes: 500)
        
        await aggregator.markSegmentComplete(segmentIndex: 0)
        await aggregator.markSegmentComplete(segmentIndex: 1)
        
        let stats = await aggregator.getDownloadStatistics()
        XCTAssertEqual(stats.bytesDownloaded, 1000)
        XCTAssertEqual(stats.completedSegments, 2)
        XCTAssertTrue(stats.isComplete)
        
        await aggregator.complete()
    }
    
    func testDownloadStatisticsCalculations() async {
        let mockProgressReporter = MockProgressReporter()
        let segmentRanges = [SegmentRange(index: 0, start: 0, end: 999)]
        
        let aggregator = ConcurrentProgressAggregator(
            totalBytes: 1000,
            progressReporter: mockProgressReporter,
            segmentRanges: segmentRanges,
            logger: logger
        )
        
        await aggregator.reportSegmentProgress(segmentIndex: 0, additionalBytes: 500)
        
        let stats = await aggregator.getDownloadStatistics()
        
        // Test byte to MB conversion
        XCTAssertEqual(stats.currentSpeedMBps, stats.currentSpeed / 1_048_576, accuracy: 0.001)
        XCTAssertEqual(stats.averageSpeedMBps, stats.averageSpeed / 1_048_576, accuracy: 0.001)
        XCTAssertEqual(stats.peakSpeedMBps, stats.peakSpeed / 1_048_576, accuracy: 0.001)
        
        // Test progress percentage
        XCTAssertEqual(stats.progressPercentage, 0.5, accuracy: 0.01)
        
        // Test completion status
        XCTAssertFalse(stats.isComplete)
        
        // Complete the download
        await aggregator.reportSegmentProgress(segmentIndex: 0, additionalBytes: 500)
        await aggregator.markSegmentComplete(segmentIndex: 0)
        
        let finalStats = await aggregator.getDownloadStatistics()
        XCTAssertTrue(finalStats.isComplete)
    }
}

// MARK: - Mock Classes

class MockProgressReporter: ProgressReporter {
    var updateCallCount = 0
    var lastBytesDownloaded: Int64?
    var lastTotalBytes: Int64?
    var lastSpeed: Double?
    var completeCalled = false
    
    override init(url: URL, quiet: Bool, totalBytes: Int64? = nil, config: ProgressDisplayConfig = .default) {
        super.init(url: url, quiet: true, totalBytes: totalBytes, config: config) // Always quiet for tests
    }
    
    override func updateProgress(bytesDownloaded: Int64, totalBytes: Int64?, speed: Double? = nil) {
        updateCallCount += 1
        lastBytesDownloaded = bytesDownloaded
        lastTotalBytes = totalBytes
        lastSpeed = speed
        // Don't call super to avoid console output
    }
    
    override func complete() {
        completeCalled = true
        // Don't call super to avoid console output
    }
}