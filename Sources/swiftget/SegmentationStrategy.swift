import Foundation
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Server capability information detected through HTTP headers and response analysis
struct ServerCapabilities {
    let acceptsRangeRequests: Bool
    let maxConnections: Int?
    let contentLength: Int64?
    let supportsPartialContent: Bool
    let serverType: String?
    
    init(acceptsRangeRequests: Bool = false, 
         maxConnections: Int? = nil,
         contentLength: Int64? = nil,
         supportsPartialContent: Bool = false,
         serverType: String? = nil) {
        self.acceptsRangeRequests = acceptsRangeRequests
        self.maxConnections = maxConnections
        self.contentLength = contentLength
        self.supportsPartialContent = supportsPartialContent
        self.serverType = serverType
    }
}

/// Network performance metrics collected during downloads
struct NetworkMetrics {
    let latency: TimeInterval
    let bandwidth: Int64 // bytes per second
    let packetLoss: Double // percentage 0.0-1.0
    let connectionCount: Int
    
    init(latency: TimeInterval = 0.1,
         bandwidth: Int64 = 1_000_000, // 1 MB/s default
         packetLoss: Double = 0.0,
         connectionCount: Int = 1) {
        self.latency = latency
        self.bandwidth = bandwidth
        self.packetLoss = packetLoss
        self.connectionCount = connectionCount
    }
}

/// Segmentation strategy configuration and metrics
struct SegmentationConfig {
    let minSegmentSize: Int64
    let maxSegmentSize: Int64
    let optimalSegmentCount: Int
    let adaptiveThreshold: Double
    
    static let `default` = SegmentationConfig(
        minSegmentSize: 1_048_576, // 1 MB
        maxSegmentSize: 104_857_600, // 100 MB
        optimalSegmentCount: 4,
        adaptiveThreshold: 0.8
    )
}

/// Performance metrics for tracking segmentation effectiveness
actor SegmentationMetrics {
    private var downloadStartTime: Date?
    private var lastSpeedCheck: Date?
    private var totalBytesDownloaded: Int64 = 0
    private var segmentPerformance: [Int: (speed: Double, reliability: Double)] = [:]
    
    func startDownload() {
        downloadStartTime = Date()
        lastSpeedCheck = Date()
        totalBytesDownloaded = 0
        segmentPerformance.removeAll()
    }
    
    func recordSegmentProgress(_ segmentIndex: Int, bytesDownloaded: Int64, duration: TimeInterval) {
        let speed = Double(bytesDownloaded) / duration
        let reliability = duration > 0 ? 1.0 : 0.0 // Simple reliability metric
        segmentPerformance[segmentIndex] = (speed: speed, reliability: reliability)
        totalBytesDownloaded += bytesDownloaded
    }
    
    func getAverageSpeed() -> Double {
        guard let startTime = downloadStartTime else { return 0.0 }
        let elapsed = Date().timeIntervalSince(startTime)
        return elapsed > 0 ? Double(totalBytesDownloaded) / elapsed : 0.0
    }
    
    func getSegmentEfficiency() -> Double {
        guard !segmentPerformance.isEmpty else { return 0.0 }
        let totalSpeed = segmentPerformance.values.reduce(0.0) { $0 + $1.speed }
        return totalSpeed / Double(segmentPerformance.count)
    }
}

/// Intelligent segmentation strategy that adapts based on file size, network conditions, and server capabilities
class SegmentationStrategy {
    private let logger: Logger
    private let config: SegmentationConfig
    private let metrics = SegmentationMetrics()
    
    init(logger: Logger, config: SegmentationConfig = .default) {
        self.logger = logger
        self.config = config
    }
    
    /// Analyze server capabilities by sending HEAD request and examining response headers
    func analyzeServerCapabilities(url: URL, session: URLSession, headers: [String: String] = [:]) async throws -> ServerCapabilities {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10.0
        
        // Add custom headers
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DownloadError.connectionFailed(underlying: NSError(domain: "Invalid response type", code: 0))
            }
            
            return parseServerCapabilities(from: httpResponse)
        } catch {
            logger.warning("Failed to analyze server capabilities: \(error)")
            // Return default capabilities on failure
            return ServerCapabilities()
        }
    }
    
    /// Calculate optimal segmentation based on file size, server capabilities, and network conditions
    func calculateOptimalSegmentation(
        contentLength: Int64,
        requestedConnections: Int,
        serverCapabilities: ServerCapabilities,
        networkMetrics: NetworkMetrics = NetworkMetrics()
    ) -> [SegmentRange] {
        
        // If server doesn't support range requests, return single segment
        guard serverCapabilities.acceptsRangeRequests else {
            logger.info("Server doesn't support range requests, using single connection")
            return [SegmentRange(index: 0, start: 0, end: contentLength - 1)]
        }
        
        // Calculate optimal number of connections
        let optimalConnections = determineOptimalConnectionCount(
            contentLength: contentLength,
            requestedConnections: requestedConnections,
            serverCapabilities: serverCapabilities,
            networkMetrics: networkMetrics
        )
        
        // Calculate segment sizes based on file size and connection count
        let segments = calculateDynamicSegments(
            contentLength: contentLength,
            connectionCount: optimalConnections
        )
        
        logger.info("Calculated \(segments.count) segments for \(contentLength) bytes (requested: \(requestedConnections), optimal: \(optimalConnections))")
        return segments
    }
    
    /// Monitor download performance and suggest segment adjustments
    func monitorPerformance(segments: [SegmentRange]) async -> SegmentationAdjustment? {
        await metrics.startDownload()
        
        let avgSpeed = await metrics.getAverageSpeed()
        let efficiency = await metrics.getSegmentEfficiency()
        
        // If efficiency is below threshold, suggest adjustments
        if efficiency < config.adaptiveThreshold {
            logger.debug("Segment efficiency below threshold (\(efficiency) < \(config.adaptiveThreshold))")
            return calculateAdjustment(currentSegments: segments, avgSpeed: avgSpeed, efficiency: efficiency)
        }
        
        return nil
    }
    
    // MARK: - Private Methods
    
    private func parseServerCapabilities(from response: HTTPURLResponse) -> ServerCapabilities {
        let acceptRanges = response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false
        let contentLength = response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        let serverType = response.value(forHTTPHeaderField: "Server")
        
        // Detect max connections from server hints
        var maxConnections: Int?
        if let serverType = serverType?.lowercased() {
            maxConnections = estimateMaxConnections(serverType: serverType)
        }
        
        // Check for partial content support
        let supportsPartialContent = response.statusCode == 206 || acceptRanges
        
        return ServerCapabilities(
            acceptsRangeRequests: acceptRanges,
            maxConnections: maxConnections,
            contentLength: contentLength,
            supportsPartialContent: supportsPartialContent,
            serverType: serverType
        )
    }
    
    private func estimateMaxConnections(serverType: String) -> Int? {
        // Heuristics based on common server types
        if serverType.contains("nginx") {
            return 8 // Nginx typically handles multiple connections well
        } else if serverType.contains("apache") {
            return 6 // Apache default configuration
        } else if serverType.contains("cloudflare") {
            return 10 // CDN can handle more connections
        } else if serverType.contains("amazon") || serverType.contains("aws") {
            return 12 // AWS infrastructure
        } else {
            return nil // Unknown server, use default logic
        }
    }
    
    private func determineOptimalConnectionCount(
        contentLength: Int64,
        requestedConnections: Int,
        serverCapabilities: ServerCapabilities,
        networkMetrics: NetworkMetrics
    ) -> Int {
        var optimalCount = requestedConnections
        
        // Respect server-indicated maximum connections
        if let maxConnections = serverCapabilities.maxConnections {
            optimalCount = min(optimalCount, maxConnections)
        }
        
        // Adjust based on file size
        let fileSize = contentLength
        switch fileSize {
        case 0..<1_048_576: // < 1 MB
            optimalCount = min(optimalCount, 1)
        case 1_048_576..<10_485_760: // 1-10 MB
            optimalCount = min(optimalCount, 2)
        case 10_485_760..<104_857_600: // 10-100 MB
            optimalCount = min(optimalCount, 4)
        case 104_857_600..<1_073_741_824: // 100MB-1GB
            optimalCount = min(optimalCount, 8)
        default: // > 1 GB
            optimalCount = min(optimalCount, 16)
        }
        
        // Adjust based on network conditions
        if networkMetrics.latency > 0.5 { // High latency
            optimalCount = min(optimalCount, optimalCount / 2)
        }
        
        if networkMetrics.packetLoss > 0.05 { // > 5% packet loss
            optimalCount = min(optimalCount, 2)
        }
        
        // Ensure minimum segment size is maintained
        let minSegments = max(1, Int(contentLength / config.maxSegmentSize))
        let maxSegments = Int(contentLength / config.minSegmentSize)
        
        optimalCount = max(minSegments, min(optimalCount, maxSegments))
        
        return max(1, optimalCount)
    }
    
    private func calculateDynamicSegments(contentLength: Int64, connectionCount: Int) -> [SegmentRange] {
        guard connectionCount > 1 else {
            return [SegmentRange(index: 0, start: 0, end: contentLength - 1)]
        }
        
        var segments: [SegmentRange] = []
        let baseSegmentSize = contentLength / Int64(connectionCount)
        let remainder = contentLength % Int64(connectionCount)
        
        var currentStart: Int64 = 0
        
        for i in 0..<connectionCount {
            // Distribute remainder across first segments
            let segmentSize = baseSegmentSize + (i < remainder ? 1 : 0)
            let segmentEnd = currentStart + segmentSize - 1
            
            // Ensure we don't exceed content length
            let actualEnd = min(segmentEnd, contentLength - 1)
            
            segments.append(SegmentRange(index: i, start: currentStart, end: actualEnd))
            currentStart = actualEnd + 1
            
            // Safety check to prevent infinite loops
            if currentStart >= contentLength {
                break
            }
        }
        
        return segments
    }
    
    private func calculateAdjustment(currentSegments: [SegmentRange], avgSpeed: Double, efficiency: Double) -> SegmentationAdjustment? {
        // Suggest fewer connections if efficiency is very low
        if efficiency < 0.5 {
            let newConnectionCount = max(1, currentSegments.count / 2)
            return SegmentationAdjustment(
                recommendedConnections: newConnectionCount,
                reason: "Low efficiency detected, reducing connections"
            )
        }
        
        // Suggest more connections if efficiency is good but could be better
        if efficiency > 0.8 && currentSegments.count < 8 {
            return SegmentationAdjustment(
                recommendedConnections: currentSegments.count + 1,
                reason: "Good efficiency, trying more connections"
            )
        }
        
        return nil
    }
}

/// Suggested adjustment to segmentation strategy
struct SegmentationAdjustment {
    let recommendedConnections: Int
    let reason: String
}

/// Segment range definition (moved from MultiConnectionDownloader for reuse)
struct SegmentRange {
    let index: Int
    let start: Int64
    let end: Int64 // inclusive
    
    var size: Int64 {
        return end - start + 1
    }
}