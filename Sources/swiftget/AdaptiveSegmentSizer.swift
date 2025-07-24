import Foundation
import Logging

/// Adaptive segment sizing based on server response times and connection performance
actor AdaptiveSegmentSizer {
    private let logger: Logger
    private var segmentPerformance: [Int: SegmentPerformance] = [:]
    private let minSegmentSize: Int64 = 64 * 1024 // 64KB minimum
    private let maxSegmentSize: Int64 = 10 * 1024 * 1024 // 10MB maximum
    
    struct SegmentPerformance {
        let downloadTime: TimeInterval
        let bytesDownloaded: Int64
        let throughput: Double // bytes per second
        let timestamp: Date
        
        var throughputMBps: Double {
            return throughput / (1024 * 1024)
        }
    }
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    /// Record performance metrics for a completed segment
    func recordSegmentPerformance(
        segmentIndex: Int,
        downloadTime: TimeInterval,
        bytesDownloaded: Int64
    ) {
        let throughput = Double(bytesDownloaded) / downloadTime
        let performance = SegmentPerformance(
            downloadTime: downloadTime,
            bytesDownloaded: bytesDownloaded,
            throughput: throughput,
            timestamp: Date()
        )
        
        segmentPerformance[segmentIndex] = performance
        
        logger.debug("Segment \(segmentIndex): \(String(format: "%.2f", performance.throughputMBps)) MB/s")
    }
    
    /// Calculate optimal segment sizes based on historical performance
    func calculateOptimalSegments(
        contentLength: Int64,
        numConnections: Int,
        serverResponseTime: TimeInterval? = nil
    ) -> [SegmentRange] {
        
        // If we have performance data, use adaptive sizing
        if !segmentPerformance.isEmpty {
            return calculateAdaptiveSegments(contentLength: contentLength, numConnections: numConnections)
        }
        
        // Otherwise, use server response time heuristics or default sizing
        return calculateInitialSegments(
            contentLength: contentLength,
            numConnections: numConnections,
            serverResponseTime: serverResponseTime
        )
    }
    
    private func calculateAdaptiveSegments(contentLength: Int64, numConnections: Int) -> [SegmentRange] {
        // Calculate average throughput from recent performance data
        let recentPerformance = segmentPerformance.values.filter { 
            Date().timeIntervalSince($0.timestamp) < 60 // Last 60 seconds
        }
        
        guard !recentPerformance.isEmpty else {
            return MultiConnectionDownloader.splitSegments(contentLength: contentLength, numSegments: numConnections)
        }
        
        let avgThroughput = recentPerformance.map { $0.throughput }.reduce(0, +) / Double(recentPerformance.count)
        let maxThroughput = recentPerformance.map { $0.throughput }.max() ?? avgThroughput
        let minThroughput = recentPerformance.map { $0.throughput }.min() ?? avgThroughput
        
        // Adjust segment sizes based on performance variance
        let performanceVariance = (maxThroughput - minThroughput) / avgThroughput
        
        if performanceVariance > 0.5 {
            // High variance: use smaller, more uniform segments
            return createUniformSegments(contentLength: contentLength, numConnections: numConnections)
        } else {
            // Low variance: use larger segments for efficiency
            return createOptimizedSegments(contentLength: contentLength, numConnections: numConnections, avgThroughput: avgThroughput)
        }
    }
    
    private func calculateInitialSegments(
        contentLength: Int64,
        numConnections: Int,
        serverResponseTime: TimeInterval?
    ) -> [SegmentRange] {
        
        // Use server response time to estimate optimal segment size
        if let responseTime = serverResponseTime {
            let optimalSegmentSize = estimateOptimalSegmentSize(
                contentLength: contentLength,
                serverResponseTime: responseTime
            )
            
            return createSegmentsWithTargetSize(
                contentLength: contentLength,
                numConnections: numConnections,
                targetSize: optimalSegmentSize
            )
        }
        
        // Default to uniform segments
        return MultiConnectionDownloader.splitSegments(contentLength: contentLength, numSegments: numConnections)
    }
    
    private func estimateOptimalSegmentSize(contentLength: Int64, serverResponseTime: TimeInterval) -> Int64 {
        // Heuristic: segment size should be large enough to amortize connection overhead
        // but small enough to allow for load balancing
        
        let connectionOverhead = serverResponseTime * 2 // Round-trip time estimate
        let targetDownloadTime: TimeInterval = 10.0 // Target 10 seconds per segment
        
        // Estimate bandwidth (very rough heuristic)
        let estimatedBandwidth = Double(contentLength) / (targetDownloadTime * 8) // bytes per second
        
        let optimalSize = Int64(estimatedBandwidth * targetDownloadTime)
        
        // Clamp to reasonable bounds
        return max(minSegmentSize, min(maxSegmentSize, optimalSize))
    }
    
    private func createUniformSegments(contentLength: Int64, numConnections: Int) -> [SegmentRange] {
        // Create smaller, uniform segments for better load balancing
        let targetSegmentSize = max(minSegmentSize, contentLength / Int64(numConnections * 2))
        let actualNumSegments = max(numConnections, Int(contentLength / targetSegmentSize))
        
        return MultiConnectionDownloader.splitSegments(contentLength: contentLength, numSegments: actualNumSegments)
    }
    
    private func createOptimizedSegments(
        contentLength: Int64,
        numConnections: Int,
        avgThroughput: Double
    ) -> [SegmentRange] {
        // Create segments optimized for current performance characteristics
        let targetSegmentTime: TimeInterval = 15.0 // Target 15 seconds per segment
        let optimalSegmentSize = Int64(avgThroughput * targetSegmentTime)
        
        return createSegmentsWithTargetSize(
            contentLength: contentLength,
            numConnections: numConnections,
            targetSize: optimalSegmentSize
        )
    }
    
    private func createSegmentsWithTargetSize(
        contentLength: Int64,
        numConnections: Int,
        targetSize: Int64
    ) -> [SegmentRange] {
        let clampedTargetSize = max(minSegmentSize, min(maxSegmentSize, targetSize))
        let numSegments = max(numConnections, Int(contentLength / clampedTargetSize))
        
        return MultiConnectionDownloader.splitSegments(contentLength: contentLength, numSegments: numSegments)
    }
    
    /// Get performance statistics for monitoring
    func getPerformanceStats() -> PerformanceStats {
        let recentPerformance = segmentPerformance.values.filter { 
            Date().timeIntervalSince($0.timestamp) < 300 // Last 5 minutes
        }
        
        guard !recentPerformance.isEmpty else {
            return PerformanceStats(
                avgThroughputMBps: 0,
                maxThroughputMBps: 0,
                minThroughputMBps: 0,
                segmentCount: 0,
                performanceVariance: 0
            )
        }
        
        let throughputs = recentPerformance.map { $0.throughputMBps }
        let avgThroughput = throughputs.reduce(0, +) / Double(throughputs.count)
        let maxThroughput = throughputs.max() ?? 0
        let minThroughput = throughputs.min() ?? 0
        let variance = throughputs.isEmpty ? 0 : (maxThroughput - minThroughput) / avgThroughput
        
        return PerformanceStats(
            avgThroughputMBps: avgThroughput,
            maxThroughputMBps: maxThroughput,
            minThroughputMBps: minThroughput,
            segmentCount: recentPerformance.count,
            performanceVariance: variance
        )
    }
    
    /// Clear old performance data to prevent memory growth
    func cleanupOldData() {
        let cutoffTime = Date().addingTimeInterval(-3600) // Keep last hour
        segmentPerformance = segmentPerformance.filter { $0.value.timestamp > cutoffTime }
    }
}

struct PerformanceStats {
    let avgThroughputMBps: Double
    let maxThroughputMBps: Double
    let minThroughputMBps: Double
    let segmentCount: Int
    let performanceVariance: Double
    
    var formattedSummary: String {
        return """
        Performance Stats:
          Avg: \(String(format: "%.2f", avgThroughputMBps)) MB/s
          Max: \(String(format: "%.2f", maxThroughputMBps)) MB/s
          Min: \(String(format: "%.2f", minThroughputMBps)) MB/s
          Segments: \(segmentCount)
          Variance: \(String(format: "%.2f", performanceVariance * 100))%
        """
    }
}
