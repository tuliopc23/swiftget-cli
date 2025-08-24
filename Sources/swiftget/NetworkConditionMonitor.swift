import Foundation
import Network
import Logging

/// Network condition monitor that tracks real-time network performance metrics
/// Uses NWPathMonitor and active probing to assess network quality and performance
actor NetworkConditionMonitor {
    
    // MARK: - Configuration
    
    /// Configuration for network monitoring behavior
    struct Configuration {
        let probingInterval: TimeInterval // How often to probe network performance
        let probingTimeout: TimeInterval // Timeout for probe requests
        let historySize: Int // Number of historical measurements to keep
        let stabilityThreshold: Int // Number of consistent readings needed for stability
        let probeUrls: [String] // URLs to use for network probing
        let enableContinuousMonitoring: Bool // Whether to monitor continuously
        
        static let `default` = Configuration(
            probingInterval: 30.0, // 30 seconds
            probingTimeout: 10.0,  // 10 seconds
            historySize: 20,
            stabilityThreshold: 3,
            probeUrls: [
                "https://www.google.com/generate_204",
                "https://www.cloudflare.com/cdn-cgi/trace",
                "https://httpbin.org/status/200"
            ],
            enableContinuousMonitoring: true
        )
        
        static let aggressive = Configuration(
            probingInterval: 10.0,
            probingTimeout: 5.0,
            historySize: 50,
            stabilityThreshold: 2,
            probeUrls: [
                "https://www.google.com/generate_204",
                "https://www.cloudflare.com/cdn-cgi/trace",
                "https://httpbin.org/status/200",
                "https://www.apple.com/library/test/success.html"
            ],
            enableContinuousMonitoring: true
        )
        
        static let conservative = Configuration(
            probingInterval: 60.0,
            probingTimeout: 15.0,
            historySize: 10,
            stabilityThreshold: 5,
            probeUrls: [
                "https://www.google.com/generate_204"
            ],
            enableContinuousMonitoring: false
        )
    }
    
    // MARK: - Properties
    
    private let configuration: Configuration
    private let logger: Logger
    private let session: URLSession
    
    // Network path monitoring
    private let pathMonitor: NWPathMonitor
    private var currentPath: NWPath?
    private var monitoringQueue: DispatchQueue
    
    // Performance metrics
    private var performanceHistory: [NetworkPerformanceMetrics] = []
    private var currentConditions: NetworkConditions
    private var lastProbeTime: Date?
    
    // Monitoring state
    private var isMonitoring: Bool = false
    private var monitoringTask: Task<Void, Never>?
    
    // Subscribers for condition changes
    private var conditionSubscribers: [UUID: (NetworkConditions) -> Void] = [:]
    
    // MARK: - Initialization
    
    init(configuration: Configuration = .default, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
        
        // Setup URLSession for probing
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.probingTimeout
        sessionConfig.timeoutIntervalForResource = configuration.probingTimeout
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: sessionConfig)
        
        // Setup network path monitoring
        self.pathMonitor = NWPathMonitor()
        self.monitoringQueue = DispatchQueue(label: "network-monitor", qos: .utility)
        
        // Initialize with unknown conditions
        self.currentConditions = NetworkConditions(
            quality: .unknown,
            bandwidth: NetworkBandwidth(),
            latency: NetworkLatency(),
            stability: .unknown,
            connectionType: .unknown,
            isExpensive: false,
            isConstrained: false,
            lastUpdated: Date()
        )
        
        setupPathMonitoring()
        
        logger.info("NetworkConditionMonitor initialized with configuration: \(configuration.probingInterval)s interval")
    }
    
    deinit {
        stopMonitoring()
    }
    
    // MARK: - Public Interface
    
    /// Start monitoring network conditions
    func startMonitoring() async {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        pathMonitor.start(queue: monitoringQueue)
        
        if configuration.enableContinuousMonitoring {
            monitoringTask = Task {
                await performContinuousMonitoring()
            }
        }
        
        // Perform initial probe
        await performNetworkProbe()
        
        logger.info("Network condition monitoring started")
    }
    
    /// Stop monitoring network conditions
    func stopMonitoring() async {
        guard isMonitoring else { return }
        
        isMonitoring = false
        pathMonitor.cancel()
        monitoringTask?.cancel()
        monitoringTask = nil
        
        logger.info("Network condition monitoring stopped")
    }
    
    /// Get current network conditions
    func getCurrentConditions() async -> NetworkConditions {
        return currentConditions
    }
    
    /// Force a network probe to update conditions
    func refreshConditions() async {
        await performNetworkProbe()
    }
    
    /// Subscribe to network condition changes
    func subscribeToConditionChanges(_ callback: @escaping (NetworkConditions) -> Void) async -> UUID {
        let id = UUID()
        conditionSubscribers[id] = callback
        
        // Send current conditions immediately
        callback(currentConditions)
        
        return id
    }
    
    /// Unsubscribe from network condition changes
    func unsubscribeFromConditionChanges(_ subscriptionId: UUID) async {
        conditionSubscribers.removeValue(forKey: subscriptionId)
    }
    
    /// Get performance history
    func getPerformanceHistory() async -> [NetworkPerformanceMetrics] {
        return performanceHistory
    }
    
    /// Get network statistics
    func getNetworkStatistics() async -> NetworkStatistics {
        guard !performanceHistory.isEmpty else {
            return NetworkStatistics()
        }
        
        let recentMetrics = performanceHistory.suffix(10)
        
        let avgLatency = recentMetrics.compactMap(\.latency).reduce(0, +) / Double(recentMetrics.count)
        let avgThroughput = recentMetrics.compactMap(\.throughput).reduce(0, +) / Double(recentMetrics.count)
        let avgPacketLoss = recentMetrics.compactMap(\.packetLoss).reduce(0, +) / Double(recentMetrics.count)
        
        let minLatency = recentMetrics.compactMap(\.latency).min() ?? 0
        let maxLatency = recentMetrics.compactMap(\.latency).max() ?? 0
        let jitter = maxLatency - minLatency
        
        return NetworkStatistics(
            averageLatency: avgLatency,
            averageThroughput: avgThroughput,
            averagePacketLoss: avgPacketLoss,
            jitter: jitter,
            stabilityScore: calculateStabilityScore(),
            measurementCount: performanceHistory.count,
            lastMeasurement: performanceHistory.last?.timestamp
        )
    }
    
    // MARK: - Private Methods
    
    private func setupPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task {
                await self?.handlePathUpdate(path)
            }
        }
    }
    
    private func handlePathUpdate(_ path: NWPath) async {
        currentPath = path
        
        let connectionType = determineConnectionType(from: path)
        let isExpensive = path.isExpensive
        let isConstrained = path.isConstrained
        
        logger.debug("Network path updated: \(connectionType), expensive: \(isExpensive), constrained: \(isConstrained)")
        
        // Update current conditions with path information
        var updatedConditions = currentConditions
        updatedConditions.connectionType = connectionType
        updatedConditions.isExpensive = isExpensive
        updatedConditions.isConstrained = isConstrained
        updatedConditions.lastUpdated = Date()
        
        await updateConditions(updatedConditions)
        
        // Trigger a probe if the path changed significantly
        if shouldProbeOnPathChange(path) {
            await performNetworkProbe()
        }
    }
    
    private func determineConnectionType(from path: NWPath) -> NetworkConnectionType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .ethernet
        } else if path.usesInterfaceType(.other) {
            return .other
        } else {
            return .unknown
        }
    }
    
    private func shouldProbeOnPathChange(_ path: NWPath) -> Bool {
        // Probe on status changes or interface type changes
        return path.status == .satisfied || path.status == .unsatisfied
    }
    
    private func performContinuousMonitoring() async {
        while isMonitoring && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(configuration.probingInterval * 1_000_000_000))
                
                if isMonitoring && !Task.isCancelled {
                    await performNetworkProbe()
                }
            } catch {
                // Sleep was cancelled, exit loop
                break
            }
        }
    }
    
    private func performNetworkProbe() async {
        guard let path = currentPath, path.status == .satisfied else {
            await updateConditions(currentConditions.withQuality(.poor))
            return
        }
        
        lastProbeTime = Date()
        logger.debug("Performing network probe")
        
        var probeResults: [ProbeResult] = []
        
        // Probe multiple URLs for better accuracy
        await withTaskGroup(of: ProbeResult?.self) { group in
            for probeUrl in configuration.probeUrls {
                group.addTask {
                    await self.probeUrl(probeUrl)
                }
            }
            
            for await result in group {
                if let result = result {
                    probeResults.append(result)
                }
            }
        }
        
        // Analyze probe results
        let metrics = analyzeProbeResults(probeResults)
        await recordPerformanceMetrics(metrics)
        
        // Update network conditions based on metrics
        let newConditions = deriveConditionsFromMetrics(metrics)
        await updateConditions(newConditions)
    }
    
    private func probeUrl(_ urlString: String) async -> ProbeResult? {
        guard let url = URL(string: urlString) else { return nil }
        
        let startTime = Date()
        
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
            let (data, response) = try await session.data(for: request)
            
            let endTime = Date()
            let responseTime = endTime.timeIntervalSince(startTime)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return ProbeResult(url: urlString, success: false, responseTime: responseTime)
            }
            
            let throughput = calculateThroughput(dataSize: data.count, duration: responseTime)
            
            return ProbeResult(
                url: urlString,
                success: true,
                responseTime: responseTime,
                dataReceived: data.count,
                throughput: throughput
            )
            
        } catch {
            let endTime = Date()
            let responseTime = endTime.timeIntervalSince(startTime)
            
            logger.debug("Probe failed for \(urlString): \(error)")
            return ProbeResult(url: urlString, success: false, responseTime: responseTime, error: error)
        }
    }
    
    private func calculateThroughput(dataSize: Int, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return Double(dataSize) / duration // bytes per second
    }
    
    private func analyzeProbeResults(_ results: [ProbeResult]) -> NetworkPerformanceMetrics {
        let successfulResults = results.filter { $0.success }
        let timestamp = Date()
        
        guard !successfulResults.isEmpty else {
            return NetworkPerformanceMetrics(
                timestamp: timestamp,
                latency: nil,
                throughput: nil,
                packetLoss: 1.0, // 100% packet loss
                responseTime: results.first?.responseTime
            )
        }
        
        let avgResponseTime = successfulResults.reduce(0) { $0 + $1.responseTime } / Double(successfulResults.count)
        let avgThroughput = successfulResults.compactMap(\.throughput).reduce(0, +) / Double(successfulResults.count)
        let packetLoss = Double(results.count - successfulResults.count) / Double(results.count)
        
        return NetworkPerformanceMetrics(
            timestamp: timestamp,
            latency: avgResponseTime * 1000, // Convert to milliseconds
            throughput: avgThroughput,
            packetLoss: packetLoss,
            responseTime: avgResponseTime
        )
    }
    
    private func recordPerformanceMetrics(_ metrics: NetworkPerformanceMetrics) async {
        performanceHistory.append(metrics)
        
        // Keep only recent history
        if performanceHistory.count > configuration.historySize {
            performanceHistory.removeFirst(performanceHistory.count - configuration.historySize)
        }
        
        logger.debug("Recorded performance metrics: latency=\(metrics.latency?.formatted() ?? "unknown")ms, throughput=\(metrics.throughput?.formatted() ?? "unknown")B/s")
    }
    
    private func deriveConditionsFromMetrics(_ metrics: NetworkPerformanceMetrics) -> NetworkConditions {
        let quality = determineNetworkQuality(from: metrics)
        let bandwidth = determineBandwidth(from: metrics)
        let latency = determineLatency(from: metrics)
        let stability = determineStability()
        
        return NetworkConditions(
            quality: quality,
            bandwidth: bandwidth,
            latency: latency,
            stability: stability,
            connectionType: currentConditions.connectionType,
            isExpensive: currentConditions.isExpensive,
            isConstrained: currentConditions.isConstrained,
            lastUpdated: Date()
        )
    }
    
    private func determineNetworkQuality(from metrics: NetworkPerformanceMetrics) -> NetworkQuality {
        // Consider multiple factors for quality assessment
        var score = 100.0
        
        // Latency factor (lower is better)
        if let latency = metrics.latency {
            switch latency {
            case 0..<50: score -= 0     // Excellent
            case 50..<100: score -= 10  // Good
            case 100..<200: score -= 30 // Fair
            case 200..<500: score -= 50 // Poor
            default: score -= 70        // Very poor
            }
        }
        
        // Packet loss factor
        if let packetLoss = metrics.packetLoss {
            score -= packetLoss * 50 // Packet loss heavily impacts quality
        }
        
        // Throughput factor
        if let throughput = metrics.throughput {
            switch throughput {
            case 1_000_000...: score += 10  // > 1 MB/s
            case 500_000..<1_000_000: score += 5  // 500KB-1MB/s
            case 100_000..<500_000: score += 0   // 100-500KB/s
            case 50_000..<100_000: score -= 10   // 50-100KB/s
            default: score -= 20                 // < 50KB/s
            }
        }
        
        // Convert score to quality level
        switch score {
        case 80...: return .excellent
        case 60..<80: return .good
        case 40..<60: return .fair
        case 20..<40: return .poor
        default: return .poor
        }
    }
    
    private func determineBandwidth(from metrics: NetworkPerformanceMetrics) -> NetworkBandwidth {
        guard let throughput = metrics.throughput else {
            return NetworkBandwidth()
        }
        
        // Estimate download and upload bandwidth (assume symmetric for now)
        let estimatedDownload = Int64(throughput * 8) // Convert bytes/s to bits/s
        let estimatedUpload = estimatedDownload / 2   // Conservative estimate
        
        return NetworkBandwidth(
            downloadBps: estimatedDownload,
            uploadBps: estimatedUpload,
            estimationAccuracy: 0.7 // Moderate confidence
        )
    }
    
    private func determineLatency(from metrics: NetworkPerformanceMetrics) -> NetworkLatency {
        guard let latency = metrics.latency else {
            return NetworkLatency()
        }
        
        // Calculate jitter from recent measurements
        let recentLatencies = performanceHistory.suffix(5).compactMap(\.latency)
        let jitter = recentLatencies.isEmpty ? 0 : (recentLatencies.max()! - recentLatencies.min()!)
        
        return NetworkLatency(
            rttMs: latency,
            jitterMs: jitter,
            confidence: 0.8
        )
    }
    
    private func determineStability() -> NetworkStability {
        guard performanceHistory.count >= configuration.stabilityThreshold else {
            return .unknown
        }
        
        let recentMetrics = performanceHistory.suffix(configuration.stabilityThreshold)
        let successCount = recentMetrics.filter { $0.packetLoss ?? 1.0 < 0.1 }.count
        let successRate = Double(successCount) / Double(recentMetrics.count)
        
        switch successRate {
        case 0.9...: return .stable
        case 0.7..<0.9: return .moderate
        case 0.5..<0.7: return .unstable
        default: return .veryUnstable
        }
    }
    
    private func calculateStabilityScore() -> Double {
        guard performanceHistory.count > 1 else { return 0.0 }
        
        let latencies = performanceHistory.compactMap(\.latency)
        guard latencies.count > 1 else { return 0.0 }
        
        let mean = latencies.reduce(0, +) / Double(latencies.count)
        let variance = latencies.reduce(0) { $0 + pow($1 - mean, 2) } / Double(latencies.count)
        let standardDeviation = sqrt(variance)
        
        // Lower coefficient of variation = higher stability
        let coefficientOfVariation = mean > 0 ? standardDeviation / mean : 1.0
        return max(0, 1.0 - coefficientOfVariation)
    }
    
    private func updateConditions(_ newConditions: NetworkConditions) async {
        let oldConditions = currentConditions
        currentConditions = newConditions
        
        // Notify subscribers if conditions changed significantly
        if hasSignificantChange(from: oldConditions, to: newConditions) {
            for callback in conditionSubscribers.values {
                callback(newConditions)
            }
            
            logger.info("Network conditions updated: \(newConditions.quality)")
        }
    }
    
    private func hasSignificantChange(from old: NetworkConditions, to new: NetworkConditions) -> Bool {
        return old.quality != new.quality ||
               old.stability != new.stability ||
               old.connectionType != new.connectionType ||
               abs(old.bandwidth.downloadBps - new.bandwidth.downloadBps) > 1_000_000 // 1 Mbps change
    }
}

// MARK: - Supporting Types

/// Network quality levels
enum NetworkQuality: String, CaseIterable, Sendable {
    case excellent = "excellent"
    case good = "good"
    case fair = "fair"
    case poor = "poor"
    case unknown = "unknown"
}

/// Network stability levels
enum NetworkStability: String, CaseIterable, Sendable {
    case stable = "stable"
    case moderate = "moderate"
    case unstable = "unstable"
    case veryUnstable = "very_unstable"
    case unknown = "unknown"
}

/// Network connection types
enum NetworkConnectionType: String, CaseIterable, Sendable {
    case wifi = "wifi"
    case cellular = "cellular"
    case ethernet = "ethernet"
    case other = "other"
    case unknown = "unknown"
}

/// Bandwidth measurements
struct NetworkBandwidth: Sendable {
    let downloadBps: Int64
    let uploadBps: Int64
    let estimationAccuracy: Double // 0.0 to 1.0
    
    init(downloadBps: Int64 = 0, uploadBps: Int64 = 0, estimationAccuracy: Double = 0.0) {
        self.downloadBps = downloadBps
        self.uploadBps = uploadBps
        self.estimationAccuracy = estimationAccuracy
    }
    
    var formattedDownload: String {
        return ByteCountFormatter.string(fromByteCount: downloadBps / 8, countStyle: .binary) + "/s"
    }
    
    var formattedUpload: String {
        return ByteCountFormatter.string(fromByteCount: uploadBps / 8, countStyle: .binary) + "/s"
    }
}

/// Latency measurements
struct NetworkLatency: Sendable {
    let rttMs: Double
    let jitterMs: Double
    let confidence: Double // 0.0 to 1.0
    
    init(rttMs: Double = 0, jitterMs: Double = 0, confidence: Double = 0.0) {
        self.rttMs = rttMs
        self.jitterMs = jitterMs
        self.confidence = confidence
    }
}

/// Complete network condition assessment
struct NetworkConditions: Sendable {
    let quality: NetworkQuality
    let bandwidth: NetworkBandwidth
    let latency: NetworkLatency
    let stability: NetworkStability
    var connectionType: NetworkConnectionType
    var isExpensive: Bool
    var isConstrained: Bool
    let lastUpdated: Date
    
    func withQuality(_ newQuality: NetworkQuality) -> NetworkConditions {
        return NetworkConditions(
            quality: newQuality,
            bandwidth: bandwidth,
            latency: latency,
            stability: stability,
            connectionType: connectionType,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            lastUpdated: Date()
        )
    }
}

/// Performance metrics from network probes
struct NetworkPerformanceMetrics: Sendable {
    let timestamp: Date
    let latency: Double? // milliseconds
    let throughput: Double? // bytes per second
    let packetLoss: Double? // ratio 0.0 to 1.0
    let responseTime: Double? // seconds
}

/// Result from individual network probe
struct ProbeResult: Sendable {
    let url: String
    let success: Bool
    let responseTime: TimeInterval
    let dataReceived: Int?
    let throughput: Double?
    let error: Error?
    
    init(url: String, success: Bool, responseTime: TimeInterval, dataReceived: Int? = nil, throughput: Double? = nil, error: Error? = nil) {
        self.url = url
        self.success = success
        self.responseTime = responseTime
        self.dataReceived = dataReceived
        self.throughput = throughput
        self.error = error
    }
}

/// Network statistics summary
struct NetworkStatistics: Sendable {
    let averageLatency: Double
    let averageThroughput: Double
    let averagePacketLoss: Double
    let jitter: Double
    let stabilityScore: Double
    let measurementCount: Int
    let lastMeasurement: Date?
    
    init(averageLatency: Double = 0, averageThroughput: Double = 0, averagePacketLoss: Double = 0,
         jitter: Double = 0, stabilityScore: Double = 0, measurementCount: Int = 0, lastMeasurement: Date? = nil) {
        self.averageLatency = averageLatency
        self.averageThroughput = averageThroughput
        self.averagePacketLoss = averagePacketLoss
        self.jitter = jitter
        self.stabilityScore = stabilityScore
        self.measurementCount = measurementCount
        self.lastMeasurement = lastMeasurement
    }
}