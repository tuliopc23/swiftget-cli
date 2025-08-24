import Foundation
import Logging

/// Segment-specific progress tracking information
struct SegmentProgress {
    let segmentIndex: Int
    var bytesDownloaded: Int64 = 0
    var totalBytes: Int64
    var startTime: Date = Date()
    var lastUpdateTime: Date = Date()
    var averageSpeed: Double = 0.0 // bytes per second
    var isComplete: Bool = false
    
    init(segmentIndex: Int, totalBytes: Int64) {
        self.segmentIndex = segmentIndex
        self.totalBytes = totalBytes
    }
    
    mutating func updateProgress(additionalBytes: Int64) {
        bytesDownloaded += additionalBytes
        lastUpdateTime = Date()
        
        let elapsedTime = lastUpdateTime.timeIntervalSince(startTime)
        if elapsedTime > 0 {
            averageSpeed = Double(bytesDownloaded) / elapsedTime
        }
        
        if bytesDownloaded >= totalBytes {
            isComplete = true
        }
    }
    
    var progressPercentage: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(Double(bytesDownloaded) / Double(totalBytes), 1.0)
    }
    
    var estimatedTimeRemaining: TimeInterval? {
        guard averageSpeed > 0, !isComplete else { return nil }
        let remainingBytes = totalBytes - bytesDownloaded
        return Double(remainingBytes) / averageSpeed
    }
}

/// Enhanced concurrent progress aggregator with real-time metrics and per-segment tracking
actor ConcurrentProgressAggregator {
    private var segments: [Int: SegmentProgress] = [:]
    private let totalBytes: Int64
    private let progressReporter: ProgressReporter
    private let logger: Logger
    private let startTime: Date = Date()
    private var lastReportTime: Date = Date()
    private let reportingInterval: TimeInterval = 0.1 // 10Hz updates
    
    // Performance metrics
    private var totalBytesDownloaded: Int64 = 0
    private var peakSpeed: Double = 0.0
    private var speedHistory: [Double] = []
    private let speedHistoryMaxSize = 50 // Keep last 50 speed measurements
    
    init(totalBytes: Int64, progressReporter: ProgressReporter, segmentRanges: [SegmentRange], logger: Logger) {
        self.totalBytes = totalBytes
        self.progressReporter = progressReporter
        self.logger = logger
        
        // Initialize segment progress tracking
        for segmentRange in segmentRanges {
            segments[segmentRange.index] = SegmentProgress(
                segmentIndex: segmentRange.index,
                totalBytes: segmentRange.size
            )
        }
        
        logger.debug("Initialized progress aggregator for \(segmentRanges.count) segments, total: \(totalBytes) bytes")
    }
    
    /// Report progress for a specific segment
    func reportSegmentProgress(segmentIndex: Int, additionalBytes: Int64) {
        guard var segment = segments[segmentIndex] else {
            logger.warning("Received progress for unknown segment \(segmentIndex)")
            return
        }
        
        segment.updateProgress(additionalBytes: additionalBytes)
        segments[segmentIndex] = segment
        totalBytesDownloaded += additionalBytes
        
        // Update speed metrics
        updateSpeedMetrics()
        
        // Report progress at controlled intervals
        let now = Date()
        if now.timeIntervalSince(lastReportTime) >= reportingInterval {
            reportAggregatedProgress()
            lastReportTime = now
        }
    }
    
    /// Mark a segment as complete
    func markSegmentComplete(segmentIndex: Int) {
        guard var segment = segments[segmentIndex] else { return }
        segment.isComplete = true
        segments[segmentIndex] = segment
        
        logger.debug("Segment \(segmentIndex) completed: \(segment.bytesDownloaded)/\(segment.totalBytes) bytes")
        
        // Force progress report when segment completes
        reportAggregatedProgress()
    }
    
    /// Get current download statistics
    func getDownloadStatistics() -> DownloadStatistics {
        let elapsedTime = Date().timeIntervalSince(startTime)
        let currentSpeed = elapsedTime > 0 ? Double(totalBytesDownloaded) / elapsedTime : 0.0
        let averageSpeed = speedHistory.isEmpty ? currentSpeed : speedHistory.reduce(0, +) / Double(speedHistory.count)
        
        let completedSegments = segments.values.filter { $0.isComplete }.count
        let activeSegments = segments.values.filter { !$0.isComplete && $0.bytesDownloaded > 0 }.count
        
        let estimatedTimeRemaining = calculateOverallETA()
        
        return DownloadStatistics(
            totalBytes: totalBytes,
            bytesDownloaded: totalBytesDownloaded,
            currentSpeed: currentSpeed,
            averageSpeed: averageSpeed,
            peakSpeed: peakSpeed,
            elapsedTime: elapsedTime,
            estimatedTimeRemaining: estimatedTimeRemaining,
            segmentCount: segments.count,
            completedSegments: completedSegments,
            activeSegments: activeSegments,
            progressPercentage: Double(totalBytesDownloaded) / Double(totalBytes)
        )
    }
    
    /// Get per-segment progress details
    func getSegmentProgress() -> [SegmentProgress] {
        return Array(segments.values).sorted { $0.segmentIndex < $1.segmentIndex }
    }
    
    /// Complete the download and perform final reporting
    func complete() async {
        progressReporter.complete()
        await finalizeStatistics()
    }
    
    // MARK: - Private Methods
    
    private func updateSpeedMetrics() {
        let elapsedTime = Date().timeIntervalSince(startTime)
        guard elapsedTime > 0 else { return }
        
        let currentSpeed = Double(totalBytesDownloaded) / elapsedTime
        
        // Update peak speed
        if currentSpeed > peakSpeed {
            peakSpeed = currentSpeed
        }
        
        // Maintain speed history for averaging
        speedHistory.append(currentSpeed)
        if speedHistory.count > speedHistoryMaxSize {
            speedHistory.removeFirst()
        }
    }
    
    private func reportAggregatedProgress() {
        // Calculate current download speed across all segments
        let activeSegments = segments.values.filter { !$0.isComplete }
        let combinedSpeed = activeSegments.reduce(0.0) { $0 + $1.averageSpeed }
        
        // Update progress reporter with aggregated data
        progressReporter.updateProgress(
            bytesDownloaded: totalBytesDownloaded, 
            totalBytes: totalBytes,
            speed: combinedSpeed
        )
        
        // Log detailed progress in verbose mode
        if logger.logLevel <= .debug {
            let progressPercent = (Double(totalBytesDownloaded) / Double(totalBytes)) * 100
            let speedMBps = combinedSpeed / 1_048_576 // Convert to MB/s
            logger.debug(Logger.Message(stringLiteral: String(format: "Progress: %.1f%% (%.2f MB/s, %d segments active)", 
                               progressPercent, speedMBps, activeSegments.count)))
        }
    }
    
    private func calculateOverallETA() -> TimeInterval? {
        let activeSegments = segments.values.filter { !$0.isComplete }
        guard !activeSegments.isEmpty else { return 0 }
        
        // Calculate weighted ETA based on remaining bytes and average speeds
        var totalRemainingBytes: Int64 = 0
        var totalSpeed: Double = 0.0
        
        for segment in activeSegments {
            let remainingBytes = segment.totalBytes - segment.bytesDownloaded
            totalRemainingBytes += remainingBytes
            totalSpeed += segment.averageSpeed
        }
        
        guard totalSpeed > 0 else { return nil }
        return Double(totalRemainingBytes) / totalSpeed
    }
    
    private func finalizeStatistics() {
        let finalStats = getDownloadStatistics()
        let speedMBps = finalStats.averageSpeed / 1_048_576
        
        logger.info(Logger.Message(stringLiteral: String(format: "Download completed: %.2f MB in %.1fs (avg: %.2f MB/s, peak: %.2f MB/s)", 
                          Double(totalBytes) / 1_048_576,
                          finalStats.elapsedTime,
                          speedMBps,
                          finalStats.peakSpeed / 1_048_576)))
        
        // Log per-segment performance summary
        for segment in segments.values.sorted(by: { $0.segmentIndex < $1.segmentIndex }) {
            let segmentSpeedMBps = segment.averageSpeed / 1_048_576
            logger.debug(Logger.Message(stringLiteral: String(format: "Segment %d: %.2f MB (%.2f MB/s)", 
                               segment.segmentIndex,
                               Double(segment.bytesDownloaded) / 1_048_576,
                               segmentSpeedMBps)))
        }
    }
}

/// Comprehensive download statistics
struct DownloadStatistics {
    let totalBytes: Int64
    let bytesDownloaded: Int64
    let currentSpeed: Double // bytes per second
    let averageSpeed: Double // bytes per second
    let peakSpeed: Double // bytes per second
    let elapsedTime: TimeInterval
    let estimatedTimeRemaining: TimeInterval?
    let segmentCount: Int
    let completedSegments: Int
    let activeSegments: Int
    let progressPercentage: Double
    
    var isComplete: Bool {
        return bytesDownloaded >= totalBytes
    }
    
    var currentSpeedMBps: Double {
        return currentSpeed / 1_048_576
    }
    
    var averageSpeedMBps: Double {
        return averageSpeed / 1_048_576
    }
    
    var peakSpeedMBps: Double {
        return peakSpeed / 1_048_576
    }
}

/// Extension to ProgressReporter to support speed reporting
extension ProgressReporter {
    func updateProgress(bytesDownloaded: Int64, totalBytes: Int64, speed: Double) {
        // This calls the original updateProgress method
        updateProgress(bytesDownloaded: bytesDownloaded, totalBytes: totalBytes)
        // The speed parameter can be used for enhanced display
        // Implementation depends on how ProgressReporter handles speed display
    }
}