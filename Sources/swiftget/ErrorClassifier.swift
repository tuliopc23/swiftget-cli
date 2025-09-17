import Foundation
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Intelligent error classifier that determines retry strategies based on error types and context
class ErrorClassifier {
    private let logger: Logger
    private let configuration: ErrorClassificationConfig
    
    init(logger: Logger, configuration: ErrorClassificationConfig = .default) {
        self.logger = logger
        self.configuration = configuration
    }
    
    /// Classify any error into a DownloadError with appropriate categorization
    func classifyError(_ error: Error, context: ErrorContext) -> DownloadError {
        logger.debug("Classifying error: \(error.localizedDescription)")
        
        // If it's already a DownloadError, return as-is
        if let downloadError = error as? DownloadError {
            return downloadError
        }
        
        // Handle URLError classification
        if let urlError = error as? URLError {
            return classifyURLError(urlError, context: context)
        }
        
        // Handle NSError classification
        if let nsError = error as? NSError {
            return classifyNSError(nsError, context: context)
        }
        
        // Handle POSIX errors
        if let posixError = error as? POSIXError {
            return classifyPOSIXError(posixError, context: context)
        }
        
        // Handle CocoaError
        if let cocoaError = error as? CocoaError {
            return classifyCocoaError(cocoaError, context: context)
        }
        
        // Default to generic network error for unknown types
        logger.warning("Unknown error type, classifying as generic network error: \(error)")
        return .connectionFailed(underlying: error)
    }
    
    /// Determine if an error should trigger a retry based on comprehensive analysis
    func shouldRetry(error: DownloadError, context: RetryContext) -> RetryDecision {
        let baseDecision = analyzeRetryability(error: error, context: context)
        let contextualDecision = applyContextualRules(baseDecision: baseDecision, error: error, context: context)
        let finalDecision = applyGlobalConstraints(decision: contextualDecision, error: error, context: context)
        
        logger.debug("Retry decision for \(error.errorCategory): \(finalDecision)")
        return finalDecision
    }
    
    /// Calculate optimal retry delay considering error type and context
    func calculateRetryDelay(for error: DownloadError, attempt: Int, context: RetryContext) -> TimeInterval {
        let baseDelay = error.suggestedRetryDelay
        let contextMultiplier = calculateContextMultiplier(error: error, context: context)
        let attemptMultiplier = calculateAttemptMultiplier(attempt: attempt, error: error)
        
        let calculatedDelay = baseDelay * contextMultiplier * attemptMultiplier
        let clampedDelay = max(configuration.minRetryDelay, min(calculatedDelay, configuration.maxRetryDelay))
        
        logger.debug("Calculated retry delay for attempt \(attempt): \(String(format: "%.2f", clampedDelay))s")
        return clampedDelay
    }
    
    /// Get retry recommendation with detailed reasoning
    func getRetryRecommendation(error: DownloadError, context: RetryContext) -> RetryRecommendation {
        let decision = shouldRetry(error: error, context: context)
        let delay = calculateRetryDelay(for: error, attempt: context.currentAttempt, context: context)
        let confidence = calculateConfidence(error: error, context: context)
        let reasoning = generateReasoning(error: error, decision: decision, context: context)
        
        return RetryRecommendation(
            decision: decision,
            suggestedDelay: delay,
            confidence: confidence,
            reasoning: reasoning,
            errorCategory: error.errorCategory,
            retryPriority: error.retryPriority
        )
    }
    
    // MARK: - Private Classification Methods
    
    private func classifyURLError(_ urlError: URLError, context: ErrorContext) -> DownloadError {
        switch urlError.code {
        // Network timeouts and connection issues
        case .timedOut:
            return .networkTimeout(urlError.localizedDescription)
        case .cannotConnectToHost:
            return .connectionFailed(underlying: urlError)
        case .networkConnectionLost:
            return .connectionLost(underlying: urlError)
        case .notConnectedToInternet:
            return .noInternetConnection
        case .cannotFindHost, .dnsLookupFailed:
            return .dnsResolutionFailed(hostname: context.url?.host ?? "unknown")
            
        // Server response errors
        case .badServerResponse:
            return .badServerResponse(statusCode: context.httpStatusCode ?? 0)
        case .resourceUnavailable:
            return .serverUnavailable(statusCode: context.httpStatusCode)
        case .httpTooManyRedirects:
            return .redirectTooMany(maxRedirects: configuration.maxRedirects)
            
        // SSL and security
        case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
            return .sslCertificateError(urlError)
        case .clientCertificateRequired, .clientCertificateRejected:
            return .authenticationRequired(scheme: "SSL Client Certificate")
            
        // File system and local errors
        case .cannotCreateFile, .cannotOpenFile, .cannotWriteToFile:
            return .fileSystemError(urlError)
        case .noPermissionsToReadFile:
            return .filePermissionDenied(path: context.filePath ?? "unknown")
        case .fileDoesNotExist:
            return .resourceNotFound(url: context.url?.absoluteString ?? "unknown")
            
        // Protocol errors
        case .unsupportedURL:
            return .protocolNotSupported(scheme: context.url?.scheme ?? "unknown")
        case .badURL:
            return .invalidURL(context.url?.absoluteString ?? "invalid")
            
        default:
            logger.warning("Unhandled URLError code: \(urlError.code.rawValue)")
            return .connectionFailed(underlying: urlError)
        }
    }
    
    private func classifyNSError(_ nsError: NSError, context: ErrorContext) -> DownloadError {
        switch nsError.domain {
        case NSPOSIXErrorDomain:
            return classifyPOSIXError(POSIXError(POSIXErrorCode(rawValue: Int32(nsError.code))!), context: context)
        case NSCocoaErrorDomain:
            return classifyCocoaError(CocoaError(CocoaError.Code(rawValue: nsError.code)), context: context)
        case "kCFErrorDomainCFNetwork":
            return classifyNetworkError(nsError, context: context)
        default:
            return .connectionFailed(underlying: nsError)
        }
    }
    
    private func classifyPOSIXError(_ posixError: POSIXError, context: ErrorContext) -> DownloadError {
        switch posixError.code {
        case .ENOSPC:
            return .diskSpaceInsufficient(required: context.requiredSpace ?? 0, available: context.availableSpace ?? 0)
        case .EACCES:
            return .filePermissionDenied(path: context.filePath ?? "unknown")
        case .EEXIST:
            return .fileAlreadyExists(path: context.filePath ?? "unknown")
        case .ENOENT:
            return .resourceNotFound(url: context.url?.absoluteString ?? "unknown")
        case .ECONNREFUSED:
            return .connectionFailed(underlying: posixError)
        case .ETIMEDOUT:
            return .networkTimeout("POSIX timeout")
        case .ENETDOWN, .ENETUNREACH:
            return .noInternetConnection
        default:
            return .fileSystemError(posixError)
        }
    }
    
    private func classifyCocoaError(_ cocoaError: CocoaError, context: ErrorContext) -> DownloadError {
        switch cocoaError.code {
        case .fileReadNoSuchFile:
            return .resourceNotFound(url: context.url?.absoluteString ?? "unknown")
        case .fileWriteNoPermission:
            return .filePermissionDenied(path: context.filePath ?? "unknown")
        case .fileWriteFileExists:
            return .fileAlreadyExists(path: context.filePath ?? "unknown")
        case .fileWriteVolumeReadOnly:
            return .filePermissionDenied(path: context.filePath ?? "read-only volume")
        default:
            return .fileSystemError(cocoaError)
        }
    }
    
    private func classifyNetworkError(_ nsError: NSError, context: ErrorContext) -> DownloadError {
        // Handle CFNetwork specific errors
        switch nsError.code {
        case -1001: // kCFURLErrorTimedOut
            return .networkTimeout("CFNetwork timeout")
        case -1004: // kCFURLErrorCannotConnectToHost
            return .connectionFailed(underlying: nsError)
        case -1005: // kCFURLErrorNetworkConnectionLost
            return .connectionLost(underlying: nsError)
        case -1009: // kCFURLErrorNotConnectedToInternet
            return .noInternetConnection
        default:
            return .connectionFailed(underlying: nsError)
        }
    }
    
    // MARK: - Retry Decision Logic
    
    private func analyzeRetryability(error: DownloadError, context: RetryContext) -> RetryDecision {
        // Check if error is fundamentally retryable
        guard error.isRetryable else {
            return .stop(reason: "Error type is not retryable: \(error.errorCategory)")
        }
        
        // Check attempt limits
        if context.currentAttempt >= error.maxRetryAttempts {
            return .stop(reason: "Maximum attempts (\(error.maxRetryAttempts)) exceeded for error type")
        }
        
        if context.currentAttempt >= configuration.globalMaxAttempts {
            return .stop(reason: "Global maximum attempts (\(configuration.globalMaxAttempts)) exceeded")
        }
        
        // Check time limits
        if let maxTime = configuration.globalMaxRetryTime,
           context.totalElapsedTime >= maxTime {
            return .stop(reason: "Global retry time limit (\(maxTime)s) exceeded")
        }
        
        // Calculate retry delay
        let delay = calculateRetryDelay(for: error, attempt: context.currentAttempt + 1, context: context)
        return .retry(after: delay)
    }
    
    private func applyContextualRules(baseDecision: RetryDecision, error: DownloadError, context: RetryContext) -> RetryDecision {
        guard case .retry(let delay) = baseDecision else { return baseDecision }
        
        // Apply download-specific rules
        if context.isMultiConnection && error.errorCategory == .downloadStrategy {
            // For multi-connection downloads with strategy errors, be more lenient
            return .retry(after: delay * 0.5)
        }
        
        if context.isResume && error.errorCategory == .contentIntegrity {
            // For resume attempts with content integrity issues, be more aggressive
            return .retry(after: delay * 2.0)
        }
        
        // Apply rate limiting awareness
        if case .rateLimited(let retryAfter) = error, let retryAfter = retryAfter {
            return .retry(after: max(delay, retryAfter))
        }
        
        // Apply network condition awareness
        if context.networkQuality == .poor && error.errorCategory == .transientNetwork {
            return .retry(after: delay * 2.0) // Longer delays on poor networks
        }
        
        return .retry(after: delay)
    }
    
    private func applyGlobalConstraints(decision: RetryDecision, error: DownloadError, context: RetryContext) -> RetryDecision {
        guard case .retry(let delay) = decision else { return decision }
        
        // Check system resources
        if configuration.respectSystemResources {
            if context.systemMemoryPressure == .high || context.systemCPUUsage > 0.9 {
                return .stop(reason: "System resources under pressure")
            }
        }
        
        // Check concurrent downloads
        if context.activeConcurrentDownloads > configuration.maxConcurrentRetries {
            return .stop(reason: "Too many concurrent retries")
        }
        
        // Apply minimum delay constraint
        let finalDelay = max(delay, configuration.minRetryDelay)
        return .retry(after: finalDelay)
    }
    
    // MARK: - Helper Methods
    
    private func calculateContextMultiplier(error: DownloadError, context: RetryContext) -> Double {
        var multiplier = 1.0
        
        // Network quality factor
        switch context.networkQuality {
        case .excellent: multiplier *= 0.8
        case .good: multiplier *= 1.0
        case .fair: multiplier *= 1.2
        case .poor: multiplier *= 1.5
        case .unknown: multiplier *= 1.1
        }
        
        // File size factor (larger files get longer delays)
        if let fileSize = context.totalFileSize {
            if fileSize > 100_000_000 { // > 100MB
                multiplier *= 1.2
            } else if fileSize < 1_000_000 { // < 1MB
                multiplier *= 0.8
            }
        }
        
        // Multi-connection factor
        if context.isMultiConnection {
            multiplier *= 0.9 // Slightly faster retries for multi-connection
        }
        
        return multiplier
    }
    
    private func calculateAttemptMultiplier(attempt: Int, error: DownloadError) -> Double {
        switch error.errorCategory {
        case .transientNetwork:
            return pow(1.5, Double(attempt - 1)) // Exponential backoff
        case .serverError:
            return pow(2.0, Double(attempt - 1)) // Aggressive exponential backoff
        case .rateLimited:
            return 1.0 // Rate limiting usually specifies exact timing
        case .contentIntegrity:
            return 1.0 + Double(attempt - 1) * 0.5 // Linear increase
        default:
            return Double(attempt) // Linear backoff
        }
    }
    
    private func calculateConfidence(error: DownloadError, context: RetryContext) -> Double {
        var confidence = 0.5 // Base confidence
        
        // Error type confidence
        switch error.errorCategory {
        case .transientNetwork: confidence += 0.3
        case .serverError: confidence += 0.2
        case .contentIntegrity: confidence += 0.25
        case .downloadStrategy: confidence += 0.15
        case .rateLimited: confidence += 0.4
        default: confidence += 0.1
        }
        
        // Attempt count factor (lower confidence with more attempts)
        confidence -= Double(context.currentAttempt) * 0.1
        
        // Context factors
        if context.hasSucceededBefore { confidence += 0.2 }
        if context.isResume { confidence += 0.1 }
        
        return max(0.0, min(1.0, confidence))
    }
    
    private func generateReasoning(error: DownloadError, decision: RetryDecision, context: RetryContext) -> String {
        switch decision {
        case .retry(let delay):
            return "Retrying in \(String(format: "%.1f", delay))s: \(error.errorCategory) errors are typically transient (attempt \(context.currentAttempt + 1)/\(error.maxRetryAttempts))"
        case .stop(let reason):
            return "Not retrying: \(reason)"
        case .circuitBreakerOpen:
            return "Circuit breaker is open due to repeated failures"
        }
    }
}

// MARK: - Configuration and Context Types

/// Configuration for error classification behavior
struct ErrorClassificationConfig {
    let globalMaxAttempts: Int
    let globalMaxRetryTime: TimeInterval?
    let minRetryDelay: TimeInterval
    let maxRetryDelay: TimeInterval
    let maxRedirects: Int
    let respectSystemResources: Bool
    let maxConcurrentRetries: Int
    
    static let `default` = ErrorClassificationConfig(
        globalMaxAttempts: 10,
        globalMaxRetryTime: 300.0, // 5 minutes
        minRetryDelay: 0.1,
        maxRetryDelay: 60.0,
        maxRedirects: 10,
        respectSystemResources: true,
        maxConcurrentRetries: 5
    )
    
    static let aggressive = ErrorClassificationConfig(
        globalMaxAttempts: 15,
        globalMaxRetryTime: 600.0, // 10 minutes
        minRetryDelay: 0.05,
        maxRetryDelay: 30.0,
        maxRedirects: 20,
        respectSystemResources: false,
        maxConcurrentRetries: 10
    )
    
    static let conservative = ErrorClassificationConfig(
        globalMaxAttempts: 5,
        globalMaxRetryTime: 120.0, // 2 minutes
        minRetryDelay: 1.0,
        maxRetryDelay: 120.0,
        maxRedirects: 5,
        respectSystemResources: true,
        maxConcurrentRetries: 2
    )
}

/// Context information for error classification
struct ErrorContext {
    let url: URL?
    let httpStatusCode: Int?
    let filePath: String?
    let requiredSpace: Int64?
    let availableSpace: Int64?
    let downloadSize: Int64?
    
    init(url: URL? = nil, httpStatusCode: Int? = nil, filePath: String? = nil, 
         requiredSpace: Int64? = nil, availableSpace: Int64? = nil, downloadSize: Int64? = nil) {
        self.url = url
        self.httpStatusCode = httpStatusCode
        self.filePath = filePath
        self.requiredSpace = requiredSpace
        self.availableSpace = availableSpace
        self.downloadSize = downloadSize
    }
}

/// Context information for retry decisions
struct RetryContext {
    let currentAttempt: Int
    let totalElapsedTime: TimeInterval
    let isMultiConnection: Bool
    let isResume: Bool
    let hasSucceededBefore: Bool
    let networkQuality: ErrorNetworkQuality
    let systemMemoryPressure: MemoryPressure
    let systemCPUUsage: Double
    let activeConcurrentDownloads: Int
    let totalFileSize: Int64?
    
    init(currentAttempt: Int = 1, totalElapsedTime: TimeInterval = 0,
         isMultiConnection: Bool = false, isResume: Bool = false,
         hasSucceededBefore: Bool = false, networkQuality: ErrorNetworkQuality = .unknown,
         systemMemoryPressure: MemoryPressure = .normal, systemCPUUsage: Double = 0.0,
         activeConcurrentDownloads: Int = 1, totalFileSize: Int64? = nil) {
        self.currentAttempt = currentAttempt
        self.totalElapsedTime = totalElapsedTime
        self.isMultiConnection = isMultiConnection
        self.isResume = isResume
        self.hasSucceededBefore = hasSucceededBefore
        self.networkQuality = networkQuality
        self.systemMemoryPressure = systemMemoryPressure
        self.systemCPUUsage = systemCPUUsage
        self.activeConcurrentDownloads = activeConcurrentDownloads
        self.totalFileSize = totalFileSize
    }
}

/// Error-specific network quality enumeration
enum ErrorNetworkQuality {
    case excellent
    case good
    case fair
    case poor
    case unknown
}

/// System memory pressure levels
enum MemoryPressure {
    case normal
    case warning
    case high
    case critical
}

/// Retry decision result
enum RetryDecision: Equatable {
    case retry(after: TimeInterval)
    case stop(reason: String)
    case circuitBreakerOpen
}

/// Comprehensive retry recommendation
struct RetryRecommendation {
    let decision: RetryDecision
    let suggestedDelay: TimeInterval
    let confidence: Double // 0.0 to 1.0
    let reasoning: String
    let errorCategory: ErrorCategory
    let retryPriority: Int
    
    var shouldRetry: Bool {
        if case .retry = decision { return true }
        return false
    }
}