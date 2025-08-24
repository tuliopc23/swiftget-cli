import Foundation
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import CoreFoundation
#endif

actor DownloadManager {
    private let configuration: DownloadConfiguration
    private let logger: Logger
    private let session: URLSession
    private let retryStrategy: RetryStrategy
    private var backoffCalculator: BackoffCalculator
    
    init(configuration: DownloadConfiguration) {
        self.configuration = configuration
        
        // Setup logger
        var logger = Logger(label: "swiftget")
        if configuration.verbose {
            logger.logLevel = .debug
        } else if configuration.quiet {
            logger.logLevel = .error
        } else {
            logger.logLevel = .info
        }
        self.logger = logger
        
        // Setup retry strategy based on configuration
        let retryConfig = Self.createRetryConfiguration(from: configuration)
        self.retryStrategy = RetryStrategy(configuration: retryConfig, logger: logger)
        
        // Setup backoff calculator for download operations
        self.backoffCalculator = BackoffCalculator.forDownloadRetries()
        
        // Setup URLSession
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 300
        
        if let proxy = configuration.proxy {
            sessionConfig.connectionProxyDictionary = Self.parseProxyConfiguration(proxy)
        }
        
        self.session = URLSession(configuration: sessionConfig)
    }
    
    func downloadUrls(_ urls: [String]) async throws {
        logger.info("Starting downloads for \(urls.count) URL(s)")
        
        for url in urls {
            do {
                try await downloadSingleUrlWithRetry(url)
            } catch {
                logger.error("Failed to download \(url) after all retry attempts: \(error)")
                if !configuration.quiet {
                    print("Error downloading \(url): \(error)")
                }
            }
        }
    }
    
    /// Download a single URL with retry logic
    private func downloadSingleUrlWithRetry(_ urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw DownloadError.invalidURL(urlString)
        }
        
        logger.debug("Starting download with retry support: \(urlString)")
        
        return try await withRetryLogic(operation: {
            try await self.downloadSingleUrl(url)
        }, context: "download \(urlString)")
    }
    
    /// Core download logic without retry (called by retry wrapper)
    private func downloadSingleUrl(_ url: URL) async throws {
        logger.debug("Executing download: \(url.absoluteString)")
        
        if configuration.connections > 1 {
            logger.debug("Using multi-connection downloader with \(configuration.connections) connections")
            let downloader = MultiConnectionDownloader(
                url: url,
                configuration: configuration,
                session: session,
                logger: logger
            )
            try await downloader.download()
        } else {
            let downloader = SimpleFileDownloader(
                url: url,
                configuration: configuration,
                session: session,
                logger: logger
            )
            try await downloader.download()
        }
    }
    
    /// Generic retry wrapper for any async operation
    private func withRetryLogic<T>(
        operation: @escaping () async throws -> T,
        context: String
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 1...retryStrategy.configuration.maxAttempts {
            do {
                let result = try await operation()
                
                if attempt > 1 {
                    logger.info("\(context) succeeded on attempt \(attempt)")
                }
                
                return result
            } catch {
                lastError = error
                
                // Check if this error should trigger a retry
                let retryDecision = retryStrategy.shouldRetry(error: error)
                
                switch retryDecision {
                case .retry(let delay):
                    logger.warning("\(context) failed on attempt \(attempt): \(error.localizedDescription)")
                    
                    if attempt < retryStrategy.configuration.maxAttempts {
                        logger.info("Retrying \(context) in \(String(format: "%.1f", delay))s (attempt \(attempt + 1)/\(retryStrategy.configuration.maxAttempts))")
                        
                        // Use backoff calculator for additional jitter if needed
                        let backoffDelay = backoffCalculator.calculateDelay(for: attempt)
                        let finalDelay = max(delay, backoffDelay)
                        
                        if finalDelay > 0 {
                            try await Task.sleep(nanoseconds: UInt64(finalDelay * 1_000_000_000))
                        }
                    }
                    
                case .stop(let reason):
                    logger.error("\(context) failed permanently: \(reason)")
                    throw error
                    
                case .circuitBreakerOpen:
                    logger.error("\(context) failed: Circuit breaker is open")
                    throw DownloadError.circuitBreakerOpen
                }
            }
        }
        
        // If we've exhausted all attempts, throw the last error
        logger.error("\(context) failed after \(retryStrategy.configuration.maxAttempts) attempts")
        throw lastError ?? DownloadError.maxRetriesExceeded
    }
    
    /// Create retry configuration based on download configuration
    private static func createRetryConfiguration(from config: DownloadConfiguration) -> RetryConfiguration {
        // Determine retry strategy based on configuration or use defaults
        let retryableErrors: Set<String> = [
            "NSURLErrorTimedOut",
            "NSURLErrorNetworkConnectionLost",
            "NSURLErrorNotConnectedToInternet",
            "NSURLErrorCannotConnectToHost",
            "NSURLErrorResourceUnavailable",
            "network_timeout",
            "connection_lost",
            "server_error",
            "rate_limited"
        ]
        
        // Choose retry configuration based on download strategy
        if config.connections > 4 {
            // For multi-connection downloads, use more aggressive retry
            return RetryConfiguration(
                maxAttempts: 5,
                backoffType: .exponential(base: 1.0, multiplier: 1.5, maxDelay: 30.0),
                jitterType: .decorrelated,
                baseDelay: 1.0,
                maxTotalTime: 300.0, // 5 minutes total
                retryableErrors: retryableErrors,
                enableCircuitBreaker: true,
                circuitBreakerThreshold: 3
            )
        } else {
            // For single/low-connection downloads, use conservative retry
            return RetryConfiguration(
                maxAttempts: 3,
                backoffType: .exponential(base: 2.0, multiplier: 2.0, maxDelay: 60.0),
                jitterType: .uniform(range: 0.8...1.2),
                baseDelay: 2.0,
                maxTotalTime: 600.0, // 10 minutes total
                retryableErrors: retryableErrors,
                enableCircuitBreaker: false,
                circuitBreakerThreshold: 5
            )
        }
    }
    
    private static func parseProxyConfiguration(_ proxyString: String) -> [String: Any] {
        guard let proxyURL = URL(string: proxyString) else {
            return [:]
        }
        
        var config: [String: Any] = [:]
        
        #if os(macOS)
        switch proxyURL.scheme?.lowercased() {
        case "http":
            config[kCFNetworkProxiesHTTPEnable as String] = true
            config[kCFNetworkProxiesHTTPProxy as String] = proxyURL.host
            if let port = proxyURL.port {
                config[kCFNetworkProxiesHTTPPort as String] = port
            }
        case "https":
            config[kCFNetworkProxiesHTTPSEnable as String] = true
            config[kCFNetworkProxiesHTTPSProxy as String] = proxyURL.host
            if let port = proxyURL.port {
                config[kCFNetworkProxiesHTTPSPort as String] = port
            }
        case "socks", "socks5":
            config[kCFNetworkProxiesSOCKSEnable as String] = true
            config[kCFNetworkProxiesSOCKSProxy as String] = proxyURL.host
            if let port = proxyURL.port {
                config[kCFNetworkProxiesSOCKSPort as String] = port
            }
        default:
            break
        }
        #else
        // On Linux, proxy configuration is more limited
        // Note: We can't use logger here since this is nonisolated
        print("Warning: Proxy configuration not fully supported on Linux")
        #endif
        
        return config
    }
}

enum DownloadError: Error, LocalizedError {
    // Connection and Network Errors
    case invalidURL(String)
    case networkTimeout(String? = nil)
    case connectionFailed(underlying: Error)
    case connectionLost(underlying: Error)
    case noInternetConnection
    case dnsResolutionFailed(hostname: String)
    
    // Server Response Errors
    case serverError(statusCode: Int, message: String? = nil)
    case badServerResponse(statusCode: Int)
    case serverTimeout(statusCode: Int? = nil)
    case serverUnavailable(statusCode: Int? = nil)
    case resourceNotFound(url: String)
    case unauthorized(realm: String? = nil)
    case forbidden(reason: String? = nil)
    case rateLimited(retryAfter: TimeInterval? = nil)
    
    // Client and Protocol Errors
    case unsupportedProtocol(String)
    case invalidRequest(reason: String)
    case redirectTooMany(maxRedirects: Int)
    case sslCertificateError(Error)
    case protocolNotSupported(scheme: String)
    
    // File System and I/O Errors
    case fileSystemError(Error)
    case diskSpaceInsufficient(required: Int64, available: Int64)
    case filePermissionDenied(path: String)
    case fileAlreadyExists(path: String)
    case fileCorrupted(path: String, reason: String? = nil)
    
    // Content and Integrity Errors
    case checksumMismatch(expected: String, actual: String)
    case contentLengthMismatch(expected: Int64, actual: Int64)
    case partialContentNotSupported
    case rangeNotSatisfiable(range: String)
    
    // Retry and Circuit Breaker Errors
    case circuitBreakerOpen
    case maxRetriesExceeded
    case retryBudgetExhausted(totalTime: TimeInterval)
    
    // Authentication and Security
    case authenticationRequired(scheme: String? = nil)
    case authenticationFailed(reason: String? = nil)
    case proxyAuthenticationRequired
    
    // Download Management Errors
    case downloadCancelled
    case downloadPaused
    case segmentationFailed(reason: String)
    case mirrorFailure(allMirrorsExhausted: Bool = false)
    
    var errorDescription: String? {
        switch self {
        // Connection and Network Errors
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .networkTimeout(let detail):
            return "Network timeout" + (detail.map { ": \($0)" } ?? "")
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .connectionLost(let error):
            return "Connection lost: \(error.localizedDescription)"
        case .noInternetConnection:
            return "No internet connection available"
        case .dnsResolutionFailed(let hostname):
            return "DNS resolution failed for hostname: \(hostname)"
            
        // Server Response Errors
        case .serverError(let statusCode, let message):
            return "Server error (\(statusCode))" + (message.map { ": \($0)" } ?? "")
        case .badServerResponse(let statusCode):
            return "Bad server response (\(statusCode))"
        case .serverTimeout(let statusCode):
            return "Server timeout" + (statusCode.map { " (\($0))" } ?? "")
        case .serverUnavailable(let statusCode):
            return "Server unavailable" + (statusCode.map { " (\($0))" } ?? "")
        case .resourceNotFound(let url):
            return "Resource not found: \(url)"
        case .unauthorized(let realm):
            return "Unauthorized access" + (realm.map { " to realm: \($0)" } ?? "")
        case .forbidden(let reason):
            return "Access forbidden" + (reason.map { ": \($0)" } ?? "")
        case .rateLimited(let retryAfter):
            return "Rate limited" + (retryAfter.map { ", retry after \($0) seconds" } ?? "")
            
        // Client and Protocol Errors
        case .unsupportedProtocol(let scheme):
            return "Unsupported protocol: \(scheme)"
        case .invalidRequest(let reason):
            return "Invalid request: \(reason)"
        case .redirectTooMany(let maxRedirects):
            return "Too many redirects (max: \(maxRedirects))"
        case .sslCertificateError(let error):
            return "SSL certificate error: \(error.localizedDescription)"
        case .protocolNotSupported(let scheme):
            return "Protocol not supported: \(scheme)"
            
        // File System and I/O Errors
        case .fileSystemError(let error):
            return "File system error: \(error.localizedDescription)"
        case .diskSpaceInsufficient(let required, let available):
            return "Insufficient disk space: required \(ByteCountFormatter.string(fromByteCount: required, countStyle: .binary)), available \(ByteCountFormatter.string(fromByteCount: available, countStyle: .binary))"
        case .filePermissionDenied(let path):
            return "File permission denied: \(path)"
        case .fileAlreadyExists(let path):
            return "File already exists: \(path)"
        case .fileCorrupted(let path, let reason):
            return "File corrupted: \(path)" + (reason.map { " (\($0))" } ?? "")
            
        // Content and Integrity Errors
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch: expected \(expected), got \(actual)"
        case .contentLengthMismatch(let expected, let actual):
            return "Content length mismatch: expected \(expected) bytes, got \(actual) bytes"
        case .partialContentNotSupported:
            return "Partial content (resume) not supported by server"
        case .rangeNotSatisfiable(let range):
            return "Range not satisfiable: \(range)"
            
        // Retry and Circuit Breaker Errors
        case .circuitBreakerOpen:
            return "Circuit breaker is open - too many consecutive failures"
        case .maxRetriesExceeded:
            return "Maximum retry attempts exceeded"
        case .retryBudgetExhausted(let totalTime):
            return "Retry budget exhausted after \(String(format: "%.1f", totalTime)) seconds"
            
        // Authentication and Security
        case .authenticationRequired(let scheme):
            return "Authentication required" + (scheme.map { " (\($0))" } ?? "")
        case .authenticationFailed(let reason):
            return "Authentication failed" + (reason.map { ": \($0)" } ?? "")
        case .proxyAuthenticationRequired:
            return "Proxy authentication required"
            
        // Download Management Errors
        case .downloadCancelled:
            return "Download was cancelled"
        case .downloadPaused:
            return "Download is paused"
        case .segmentationFailed(let reason):
            return "Segmentation failed: \(reason)"
        case .mirrorFailure(let allMirrorsExhausted):
            return allMirrorsExhausted ? "All mirrors exhausted" : "Mirror failure"
        }
    }
    
    /// Error classification for retry logic
    var errorCategory: ErrorCategory {
        switch self {
        // Retryable network/connection errors
        case .networkTimeout, .connectionFailed, .connectionLost, .noInternetConnection, .dnsResolutionFailed:
            return .transientNetwork
            
        // Server errors that might be temporary
        case .serverError(let statusCode, _), .badServerResponse(let statusCode):
            if statusCode >= 500 { return .serverError }
            else if statusCode == 429 { return .rateLimited }
            else if statusCode >= 400 { return .clientError }
            else { return .unknown }
            
        case .serverTimeout(let statusCode), .serverUnavailable(let statusCode):
            return statusCode.map { code in
                if code >= 500 { return .serverError }
                else if code == 429 { return .rateLimited }
                else if code >= 400 { return .clientError }
                else { return .unknown }
            } ?? .serverError
            
        case .rateLimited:
            return .rateLimited
            
        // Client errors - generally not retryable
        case .invalidURL, .unsupportedProtocol, .invalidRequest, .unauthorized, .forbidden, .resourceNotFound:
            return .clientError
            
        // Protocol errors
        case .redirectTooMany, .sslCertificateError, .protocolNotSupported, .partialContentNotSupported, .rangeNotSatisfiable:
            return .protocolError
            
        // File system errors - context dependent
        case .fileSystemError, .filePermissionDenied, .fileAlreadyExists:
            return .fileSystemError
            
        case .diskSpaceInsufficient:
            return .resourceExhausted
            
        // Content integrity errors - might be retryable
        case .checksumMismatch, .contentLengthMismatch, .fileCorrupted:
            return .contentIntegrity
            
        // Retry mechanism errors
        case .circuitBreakerOpen, .maxRetriesExceeded, .retryBudgetExhausted:
            return .retryExhausted
            
        // Authentication - context dependent
        case .authenticationRequired, .authenticationFailed, .proxyAuthenticationRequired:
            return .authentication
            
        // Management errors
        case .downloadCancelled, .downloadPaused:
            return .management
            
        case .segmentationFailed, .mirrorFailure:
            return .downloadStrategy
        }
    }
    
    /// Whether this error type is generally retryable
    var isRetryable: Bool {
        switch errorCategory {
        case .transientNetwork, .serverError, .rateLimited, .contentIntegrity, .downloadStrategy:
            return true
        case .clientError, .protocolError, .fileSystemError, .resourceExhausted, .retryExhausted, .authentication, .management:
            return false
        case .unknown:
            return false // Conservative approach
        }
    }
    
    /// Suggested retry delay based on error type
    var suggestedRetryDelay: TimeInterval {
        switch self {
        case .rateLimited(let retryAfter):
            return retryAfter ?? 60.0 // Default to 1 minute if not specified
        case .networkTimeout, .connectionFailed, .connectionLost:
            return 2.0
        case .serverError, .serverTimeout, .serverUnavailable:
            return 5.0
        case .dnsResolutionFailed:
            return 10.0
        case .checksumMismatch, .contentLengthMismatch:
            return 1.0
        default:
            return 0.0 // No delay for non-retryable errors
        }
    }
    
    /// Maximum retry attempts recommended for this error type
    var maxRetryAttempts: Int {
        switch errorCategory {
        case .transientNetwork:
            return 5
        case .serverError:
            return 3
        case .rateLimited:
            return 2
        case .contentIntegrity:
            return 3
        case .downloadStrategy:
            return 2
        default:
            return 0 // No retries for other categories
        }
    }
    
    /// Priority level for retry (higher = more important to retry)
    var retryPriority: Int {
        switch errorCategory {
        case .transientNetwork: return 8
        case .contentIntegrity: return 7
        case .downloadStrategy: return 6
        case .serverError: return 5
        case .rateLimited: return 4
        case .authentication: return 3
        case .protocolError: return 2
        case .fileSystemError: return 1
        default: return 0
        }
    }
}

/// Error categories for classification and retry logic
enum ErrorCategory {
    case transientNetwork     // Network issues that are likely temporary
    case serverError         // 5xx server errors
    case clientError         // 4xx client errors
    case rateLimited         // 429 rate limiting
    case protocolError       // HTTP/Protocol issues
    case fileSystemError     // Local file system problems
    case resourceExhausted   // Out of disk space, memory, etc.
    case contentIntegrity    // Checksum, corruption issues
    case retryExhausted      // Retry mechanisms exhausted
    case authentication      // Auth related errors
    case management          // Download management (pause, cancel)
    case downloadStrategy    // Segmentation, mirror issues
    case unknown             // Unclassified errors
}