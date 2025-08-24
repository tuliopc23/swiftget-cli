import Foundation
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Types of segment errors that can occur during download
enum SegmentErrorType: String, CaseIterable {
    case networkTimeout = "network_timeout"
    case connectionLost = "connection_lost"
    case serverError = "server_error"
    case rateLimited = "rate_limited"
    case partialContentError = "partial_content_error"
    case corruptedData = "corrupted_data"
    case diskSpaceError = "disk_space_error"
    case unknownError = "unknown_error"
    
    /// Whether this error type should trigger a retry
    var isRetryable: Bool {
        switch self {
        case .networkTimeout, .connectionLost, .serverError, .rateLimited:
            return true
        case .partialContentError, .corruptedData:
            return true
        case .diskSpaceError, .unknownError:
            return false
        }
    }
    
    /// Default retry delay for this error type
    var baseRetryDelay: TimeInterval {
        switch self {
        case .networkTimeout, .connectionLost:
            return 1.0
        case .serverError:
            return 2.0
        case .rateLimited:
            return 5.0
        case .partialContentError, .corruptedData:
            return 0.5
        case .diskSpaceError, .unknownError:
            return 0.0
        }
    }
    
    /// Maximum retry attempts for this error type
    var maxRetryAttempts: Int {
        switch self {
        case .networkTimeout, .connectionLost:
            return 5
        case .serverError:
            return 3
        case .rateLimited:
            return 2
        case .partialContentError, .corruptedData:
            return 3
        case .diskSpaceError, .unknownError:
            return 0
        }
    }
}

/// Detailed segment error information
struct SegmentError: Error {
    let segmentIndex: Int
    let errorType: SegmentErrorType
    let underlyingError: Error?
    let timestamp: Date
    let attemptNumber: Int
    let bytesTransferred: Int64
    
    init(segmentIndex: Int, errorType: SegmentErrorType, underlyingError: Error? = nil, attemptNumber: Int = 1, bytesTransferred: Int64 = 0) {
        self.segmentIndex = segmentIndex
        self.errorType = errorType
        self.underlyingError = underlyingError
        self.timestamp = Date()
        self.attemptNumber = attemptNumber
        self.bytesTransferred = bytesTransferred
    }
    
    var localizedDescription: String {
        let baseMessage = "Segment \(segmentIndex) failed: \(errorType.rawValue)"
        if let underlying = underlyingError {
            return "\(baseMessage) - \(underlying.localizedDescription)"
        }
        return baseMessage
    }
}

/// Segment retry state tracking
struct SegmentRetryState {
    let segmentIndex: Int
    var attemptCount: Int = 0
    var lastError: SegmentError?
    var totalBytesTransferred: Int64 = 0
    var backoffMultiplier: Double = 1.0
    var isRedistributed: Bool = false
    var redistributionTargets: [Int] = []
    
    init(segmentIndex: Int) {
        self.segmentIndex = segmentIndex
    }
    
    mutating func recordFailure(_ error: SegmentError) {
        attemptCount += 1
        lastError = error
        totalBytesTransferred = max(totalBytesTransferred, error.bytesTransferred)
        backoffMultiplier = min(backoffMultiplier * 1.5, 8.0) // Cap at 8x delay
    }
    
    mutating func resetForRedistribution() {
        attemptCount = 0
        backoffMultiplier = 1.0
        isRedistributed = true
    }
    
    var shouldRetry: Bool {
        guard let error = lastError else { return true }
        return error.errorType.isRetryable && attemptCount < error.errorType.maxRetryAttempts
    }
    
    var nextRetryDelay: TimeInterval {
        guard let error = lastError else { return 0 }
        return error.errorType.baseRetryDelay * backoffMultiplier
    }
}

/// Recovery strategy for segment failures
enum RecoveryStrategy {
    case retry           // Retry the same segment
    case redistribute    // Split segment among other active segments
    case fallback        // Fall back to single-connection download
    case abort           // Abort the entire download
}

/// Configuration for error recovery behavior
struct ErrorRecoveryConfig {
    let maxTotalRetries: Int
    let maxRedistributions: Int
    let fallbackThreshold: Double // Percentage of segments that must fail to trigger fallback
    let redistributionSizeThreshold: Int64 // Minimum segment size to allow redistribution
    let enableFallback: Bool
    
    static let `default` = ErrorRecoveryConfig(
        maxTotalRetries: 15,
        maxRedistributions: 3,
        fallbackThreshold: 0.5, // 50% of segments
        redistributionSizeThreshold: 1_048_576, // 1 MB
        enableFallback: true
    )
    
    static let aggressive = ErrorRecoveryConfig(
        maxTotalRetries: 25,
        maxRedistributions: 5,
        fallbackThreshold: 0.7, // 70% of segments
        redistributionSizeThreshold: 512_000, // 512 KB
        enableFallback: true
    )
    
    static let conservative = ErrorRecoveryConfig(
        maxTotalRetries: 5,
        maxRedistributions: 1,
        fallbackThreshold: 0.3, // 30% of segments
        redistributionSizeThreshold: 2_097_152, // 2 MB
        enableFallback: true
    )
}

/// Actor responsible for managing segment error recovery and redistribution
actor SegmentErrorRecovery {
    private let logger: Logger
    private let config: ErrorRecoveryConfig
    private var segmentStates: [Int: SegmentRetryState] = [:]
    private var totalRetries: Int = 0
    private var totalRedistributions: Int = 0
    private var originalSegments: [SegmentRange] = []
    private var activeSegments: Set<Int> = []
    
    init(logger: Logger, config: ErrorRecoveryConfig = .default) {
        self.logger = logger
        self.config = config
    }
    
    /// Initialize recovery tracking for segments
    func initializeSegments(_ segments: [SegmentRange]) {
        originalSegments = segments
        activeSegments = Set(segments.map { $0.index })
        
        for segment in segments {
            segmentStates[segment.index] = SegmentRetryState(segmentIndex: segment.index)
        }
        
        logger.info("Initialized error recovery for \(segments.count) segments")
    }
    
    /// Classify error based on the underlying error type
    func classifyError(_ error: Error, segmentIndex: Int, attemptNumber: Int, bytesTransferred: Int64) -> SegmentError {
        let errorType: SegmentErrorType
        
        if let urlError = error as? URLError {
            errorType = classifyURLError(urlError)
        } else if let downloadError = error as? DownloadError {
            errorType = classifyDownloadError(downloadError)
        } else {
            errorType = .unknownError
        }
        
        return SegmentError(
            segmentIndex: segmentIndex,
            errorType: errorType,
            underlyingError: error,
            attemptNumber: attemptNumber,
            bytesTransferred: bytesTransferred
        )
    }
    
    /// Handle segment failure and determine recovery strategy
    func handleSegmentFailure(_ error: SegmentError) async -> RecoveryStrategy {
        guard var state = segmentStates[error.segmentIndex] else {
            logger.error("Unknown segment index: \(error.segmentIndex)")
            return .abort
        }
        
        state.recordFailure(error)
        segmentStates[error.segmentIndex] = state
        totalRetries += 1
        
        logger.warning("Segment \(error.segmentIndex) failed (attempt \(state.attemptCount)): \(error.errorType.rawValue)")
        
        // Check if we should abort due to too many total retries
        if totalRetries >= config.maxTotalRetries {
            logger.error("Maximum total retries (\(config.maxTotalRetries)) exceeded, aborting download")
            return .abort
        }
        
        // Check if segment should be retried
        if state.shouldRetry {
            let delay = state.nextRetryDelay
            logger.info("Retrying segment \(error.segmentIndex) in \(String(format: "%.1f", delay))s")
            
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            return .retry
        }
        
        // Remove failed segment from active segments
        activeSegments.remove(error.segmentIndex)
        
        // Calculate failure percentage
        let failedSegments = originalSegments.count - activeSegments.count
        let failurePercentage = Double(failedSegments) / Double(originalSegments.count)
        
        // Check if we should fall back to single connection
        if config.enableFallback && failurePercentage >= config.fallbackThreshold {
            logger.warning("Failure rate (\(String(format: "%.1f", failurePercentage * 100))%) exceeds threshold, falling back to single connection")
            return .fallback
        }
        
        // Try redistribution if possible
        if canRedistributeSegment(error.segmentIndex) {
            logger.info("Attempting to redistribute segment \(error.segmentIndex)")
            return .redistribute
        }
        
        // If redistribution is not possible and we still have active segments, continue
        if !activeSegments.isEmpty {
            logger.info("Continuing download with remaining \(activeSegments.count) segments")
            return .retry // Let other segments continue
        }
        
        // No active segments left
        logger.error("No active segments remaining, aborting download")
        return .abort
    }
    
    /// Redistribute a failed segment's remaining work among active segments
    func redistributeSegment(_ segmentIndex: Int, amongSegments activeSegmentIndices: [Int]) async -> [SegmentRange] {
        guard let originalSegment = originalSegments.first(where: { $0.index == segmentIndex }),
              !activeSegmentIndices.isEmpty,
              totalRedistributions < config.maxRedistributions else {
            logger.warning("Cannot redistribute segment \(segmentIndex)")
            return []
        }
        
        totalRedistributions += 1
        
        // Calculate remaining bytes for the failed segment
        let transferredBytes = segmentStates[segmentIndex]?.totalBytesTransferred ?? 0
        let remainingBytes = originalSegment.size - transferredBytes
        
        guard remainingBytes > 0 else {
            logger.info("Segment \(segmentIndex) has no remaining bytes to redistribute")
            return []
        }
        
        // Create new segments for redistribution
        let newSegments = createRedistributionSegments(
            remainingBytes: remainingBytes,
            startOffset: originalSegment.start + transferredBytes,
            targetSegments: activeSegmentIndices
        )
        
        // Update segment states
        if var state = segmentStates[segmentIndex] {
            state.resetForRedistribution()
            state.redistributionTargets = newSegments.map { $0.index }
            segmentStates[segmentIndex] = state
        }
        
        logger.info("Redistributed \(remainingBytes) bytes from segment \(segmentIndex) into \(newSegments.count) new segments")
        
        return newSegments
    }
    
    /// Get current recovery statistics
    func getRecoveryStatistics() -> RecoveryStatistics {
        let failedSegments = segmentStates.values.filter { !$0.shouldRetry && !$0.isRedistributed }
        let retriedSegments = segmentStates.values.filter { $0.attemptCount > 1 }
        let redistributedSegments = segmentStates.values.filter { $0.isRedistributed }
        
        return RecoveryStatistics(
            totalRetries: totalRetries,
            totalRedistributions: totalRedistributions,
            failedSegmentCount: failedSegments.count,
            retriedSegmentCount: retriedSegments.count,
            redistributedSegmentCount: redistributedSegments.count,
            activeSegmentCount: activeSegments.count
        )
    }
    
    // MARK: - Private Methods
    
    private func classifyURLError(_ urlError: URLError) -> SegmentErrorType {
        switch urlError.code {
        case .timedOut:
            return .networkTimeout
        case .networkConnectionLost, .notConnectedToInternet:
            return .connectionLost
        case .badServerResponse, .cannotFindHost, .cannotConnectToHost:
            return .serverError
        case .resourceUnavailable:
            return .rateLimited
        default:
            return .unknownError
        }
    }
    
    private func classifyDownloadError(_ downloadError: DownloadError) -> SegmentErrorType {
        switch downloadError {
        case .connectionFailed, .connectionLost, .networkTimeout:
            return .connectionLost
        case .fileSystemError:
            return .diskSpaceError
        case .checksumMismatch:
            return .corruptedData
        default:
            return .unknownError
        }
    }
    
    private func canRedistributeSegment(_ segmentIndex: Int) -> Bool {
        guard totalRedistributions < config.maxRedistributions,
              let segment = originalSegments.first(where: { $0.index == segmentIndex }),
              segment.size >= config.redistributionSizeThreshold,
              activeSegments.count > 0 else {
            return false
        }
        
        return true
    }
    
    private func createRedistributionSegments(remainingBytes: Int64, startOffset: Int64, targetSegments: [Int]) -> [SegmentRange] {
        let segmentCount = min(targetSegments.count, 4) // Limit redistribution segments
        let bytesPerSegment = remainingBytes / Int64(segmentCount)
        let extraBytes = remainingBytes % Int64(segmentCount)
        
        var newSegments: [SegmentRange] = []
        var currentOffset = startOffset
        
        for i in 0..<segmentCount {
            let segmentSize = bytesPerSegment + (i < extraBytes ? 1 : 0)
            let endOffset = currentOffset + segmentSize - 1
            
            // Use negative indices for redistributed segments to avoid conflicts
            let newIndex = -(1000 + totalRedistributions * 10 + i)
            
            newSegments.append(SegmentRange(
                index: newIndex,
                start: currentOffset,
                end: endOffset
            ))
            
            currentOffset = endOffset + 1
        }
        
        return newSegments
    }
}

/// Recovery statistics for monitoring and debugging
struct RecoveryStatistics {
    let totalRetries: Int
    let totalRedistributions: Int
    let failedSegmentCount: Int
    let retriedSegmentCount: Int
    let redistributedSegmentCount: Int
    let activeSegmentCount: Int
    
    var failureRate: Double {
        let totalSegments = failedSegmentCount + redistributedSegmentCount + activeSegmentCount
        return totalSegments > 0 ? Double(failedSegmentCount) / Double(totalSegments) : 0.0
    }
    
    var redistributionRate: Double {
        let totalSegments = failedSegmentCount + redistributedSegmentCount + activeSegmentCount
        return totalSegments > 0 ? Double(redistributedSegmentCount) / Double(totalSegments) : 0.0
    }
}