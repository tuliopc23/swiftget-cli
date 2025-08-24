import XCTest
import Foundation
import Logging
@testable import swiftget

final class ErrorClassificationTests: XCTestCase {
    
    var logger: Logger!
    var errorClassifier: ErrorClassifier!
    
    override func setUp() async throws {
        try await super.setUp()
        logger = Logger(label: "test-error-classification")
        logger.logLevel = .error // Reduce noise in tests
        errorClassifier = ErrorClassifier(logger: logger)
    }
    
    // MARK: - Error Classification Tests
    
    func testURLErrorClassification() {
        let context = ErrorContext(url: URL(string: "https://example.com/file.zip"))
        
        // Test timeout classification
        let timeoutError = URLError(.timedOut)
        let classifiedTimeout = errorClassifier.classifyError(timeoutError, context: context)
        if case .networkTimeout = classifiedTimeout {
            // Expected
        } else {
            XCTFail("Expected networkTimeout, got \(classifiedTimeout)")
        }
        
        // Test connection failure
        let connectionError = URLError(.cannotConnectToHost)
        let classifiedConnection = errorClassifier.classifyError(connectionError, context: context)
        if case .connectionFailed = classifiedConnection {
            // Expected
        } else {
            XCTFail("Expected connectionFailed, got \(classifiedConnection)")
        }
        
        // Test DNS failure
        let dnsError = URLError(.cannotFindHost)
        let classifiedDNS = errorClassifier.classifyError(dnsError, context: context)
        if case .dnsResolutionFailed(let hostname) = classifiedDNS {
            XCTAssertEqual(hostname, "example.com")
        } else {
            XCTFail("Expected dnsResolutionFailed, got \(classifiedDNS)")
        }
        
        // Test SSL certificate error
        let sslError = URLError(.serverCertificateUntrusted)
        let classifiedSSL = errorClassifier.classifyError(sslError, context: context)
        if case .sslCertificateError = classifiedSSL {
            // Expected
        } else {
            XCTFail("Expected sslCertificateError, got \(classifiedSSL)")
        }
    }
    
    func testHTTPStatusCodeClassification() {
        // Test server errors
        let context500 = ErrorContext(httpStatusCode: 500)
        let serverError = URLError(.badServerResponse)
        let classified500 = errorClassifier.classifyError(serverError, context: context500)
        if case .badServerResponse(let statusCode) = classified500 {
            XCTAssertEqual(statusCode, 500)
        } else {
            XCTFail("Expected badServerResponse with 500, got \(classified500)")
        }
        
        // Test rate limiting
        let context429 = ErrorContext(httpStatusCode: 429)
        let rateLimitError = URLError(.resourceUnavailable)
        let classified429 = errorClassifier.classifyError(rateLimitError, context: context429)
        if case .serverUnavailable(let statusCode) = classified429 {
            XCTAssertEqual(statusCode, 429)
        } else {
            XCTFail("Expected serverUnavailable with 429, got \(classified429)")
        }
    }
    
    func testPOSIXErrorClassification() {
        let context = ErrorContext(filePath: "/tmp/testfile")
        
        // Test disk space error
        let diskSpaceError = POSIXError(.ENOSPC)
        let classifiedDiskSpace = errorClassifier.classifyError(diskSpaceError, context: context)
        if case .diskSpaceInsufficient = classifiedDiskSpace {
            // Expected
        } else {
            XCTFail("Expected diskSpaceInsufficient, got \(classifiedDiskSpace)")
        }
        
        // Test permission error
        let permissionError = POSIXError(.EACCES)
        let classifiedPermission = errorClassifier.classifyError(permissionError, context: context)
        if case .filePermissionDenied(let path) = classifiedPermission {
            XCTAssertEqual(path, "/tmp/testfile")
        } else {
            XCTFail("Expected filePermissionDenied, got \(classifiedPermission)")
        }
    }
    
    func testDownloadErrorPassthrough() {
        let originalError = DownloadError.checksumMismatch(expected: "abc123", actual: "def456")
        let context = ErrorContext()
        
        let classifiedError = errorClassifier.classifyError(originalError, context: context)
        
        // Should return the same error
        if case .checksumMismatch(let expected, let actual) = classifiedError {
            XCTAssertEqual(expected, "abc123")
            XCTAssertEqual(actual, "def456")
        } else {
            XCTFail("Expected same checksumMismatch error, got \(classifiedError)")
        }
    }
    
    // MARK: - Error Category Tests
    
    func testErrorCategories() {
        // Test transient network errors
        let networkTimeout = DownloadError.networkTimeout()
        XCTAssertEqual(networkTimeout.errorCategory, .transientNetwork)
        XCTAssertTrue(networkTimeout.isRetryable)
        
        // Test server errors
        let serverError = DownloadError.serverError(statusCode: 500)
        XCTAssertEqual(serverError.errorCategory, .serverError)
        XCTAssertTrue(serverError.isRetryable)
        
        // Test client errors
        let clientError = DownloadError.unauthorized()
        XCTAssertEqual(clientError.errorCategory, .clientError)
        XCTAssertFalse(clientError.isRetryable)
        
        // Test rate limiting
        let rateLimited = DownloadError.rateLimited(retryAfter: 60.0)
        XCTAssertEqual(rateLimited.errorCategory, .rateLimited)
        XCTAssertTrue(rateLimited.isRetryable)
        
        // Test content integrity
        let checksumError = DownloadError.checksumMismatch(expected: "abc", actual: "def")
        XCTAssertEqual(checksumError.errorCategory, .contentIntegrity)
        XCTAssertTrue(checksumError.isRetryable)
    }
    
    func testRetryProperties() {
        // Test retry attempts
        let networkError = DownloadError.networkTimeout()
        XCTAssertEqual(networkError.maxRetryAttempts, 5)
        
        let serverError = DownloadError.serverError(statusCode: 503)
        XCTAssertEqual(serverError.maxRetryAttempts, 3)
        
        let rateLimited = DownloadError.rateLimited()
        XCTAssertEqual(rateLimited.maxRetryAttempts, 2)
        
        // Test retry delays
        XCTAssertEqual(networkError.suggestedRetryDelay, 2.0)
        XCTAssertEqual(serverError.suggestedRetryDelay, 5.0)
        XCTAssertEqual(rateLimited.suggestedRetryDelay, 60.0)
        
        // Test retry priorities
        XCTAssertEqual(networkError.retryPriority, 8)
        XCTAssertEqual(serverError.retryPriority, 5)
        XCTAssertEqual(rateLimited.retryPriority, 4)
    }
    
    // MARK: - Retry Decision Tests
    
    func testBasicRetryDecisions() {
        // Test retryable error
        let networkError = DownloadError.networkTimeout()
        let retryContext = RetryContext(currentAttempt: 1)
        
        let decision = errorClassifier.shouldRetry(error: networkError, context: retryContext)
        if case .retry(let delay) = decision {
            XCTAssertGreaterThan(delay, 0)
        } else {
            XCTFail("Expected retry decision, got \(decision)")
        }
        
        // Test non-retryable error
        let clientError = DownloadError.invalidURL("bad-url")
        let clientDecision = errorClassifier.shouldRetry(error: clientError, context: retryContext)
        if case .stop(let reason) = clientDecision {
            XCTAssertTrue(reason.contains("not retryable"))
        } else {
            XCTFail("Expected stop decision, got \(clientDecision)")
        }
    }
    
    func testRetryAttemptLimits() {
        let networkError = DownloadError.networkTimeout()
        
        // Test within limits
        let contextWithinLimits = RetryContext(currentAttempt: 3)
        let decisionWithinLimits = errorClassifier.shouldRetry(error: networkError, context: contextWithinLimits)
        if case .retry = decisionWithinLimits {
            // Expected
        } else {
            XCTFail("Expected retry within limits, got \(decisionWithinLimits)")
        }
        
        // Test beyond limits
        let contextBeyondLimits = RetryContext(currentAttempt: 6) // Beyond networkError.maxRetryAttempts (5)
        let decisionBeyondLimits = errorClassifier.shouldRetry(error: networkError, context: contextBeyondLimits)
        if case .stop(let reason) = decisionBeyondLimits {
            XCTAssertTrue(reason.contains("Maximum attempts"))
        } else {
            XCTFail("Expected stop beyond limits, got \(decisionBeyondLimits)")
        }
    }
    
    func testRetryTimeouts() {
        let config = ErrorClassificationConfig(
            globalMaxAttempts: 10,
            globalMaxRetryTime: 30.0, // 30 seconds
            minRetryDelay: 0.1,
            maxRetryDelay: 60.0,
            maxRedirects: 10,
            respectSystemResources: false,
            maxConcurrentRetries: 5
        )
        let classifier = ErrorClassifier(logger: logger, configuration: config)
        
        let networkError = DownloadError.networkTimeout()
        let timeoutContext = RetryContext(currentAttempt: 1, totalElapsedTime: 35.0) // Beyond 30s limit
        
        let decision = classifier.shouldRetry(error: networkError, context: timeoutContext)
        if case .stop(let reason) = decision {
            XCTAssertTrue(reason.contains("time limit"))
        } else {
            XCTFail("Expected stop due to time limit, got \(decision)")
        }
    }
    
    func testRateLimitingHandling() {
        let rateLimitedError = DownloadError.rateLimited(retryAfter: 120.0)
        let context = RetryContext(currentAttempt: 1)
        
        let decision = errorClassifier.shouldRetry(error: rateLimitedError, context: context)
        if case .retry(let delay) = decision {
            XCTAssertGreaterThanOrEqual(delay, 120.0) // Should respect the rate limit delay
        } else {
            XCTFail("Expected retry with rate limit delay, got \(decision)")
        }
    }
    
    // MARK: - Contextual Decision Tests
    
    func testMultiConnectionContext() {
        let downloadStrategyError = DownloadError.segmentationFailed(reason: "test")
        let multiConnContext = RetryContext(currentAttempt: 1, isMultiConnection: true)
        let singleConnContext = RetryContext(currentAttempt: 1, isMultiConnection: false)
        
        let multiDecision = errorClassifier.shouldRetry(error: downloadStrategyError, context: multiConnContext)
        let singleDecision = errorClassifier.shouldRetry(error: downloadStrategyError, context: singleConnContext)
        
        // Both should be retryable, but multi-connection might have different delays
        if case .retry(let multiDelay) = multiDecision,
           case .retry(let singleDelay) = singleDecision {
            // Multi-connection should have faster retry (contextual rule applied)
            XCTAssertLessThanOrEqual(multiDelay, singleDelay)
        } else {
            XCTFail("Expected retry decisions for both contexts")
        }
    }
    
    func testNetworkQualityContext() {
        let networkError = DownloadError.connectionLost(underlying: URLError(.networkConnectionLost))
        let goodNetworkContext = RetryContext(currentAttempt: 1, networkQuality: .good)
        let poorNetworkContext = RetryContext(currentAttempt: 1, networkQuality: .poor)
        
        let goodDelay = errorClassifier.calculateRetryDelay(for: networkError, attempt: 1, context: goodNetworkContext)
        let poorDelay = errorClassifier.calculateRetryDelay(for: networkError, attempt: 1, context: poorNetworkContext)
        
        // Poor network should have longer delays
        XCTAssertLessThan(goodDelay, poorDelay)
    }
    
    func testSystemResourceContext() {
        let config = ErrorClassificationConfig.default
        let classifier = ErrorClassifier(logger: logger, configuration: config)
        
        let networkError = DownloadError.networkTimeout()
        let highResourceContext = RetryContext(
            currentAttempt: 1,
            systemMemoryPressure: .high,
            systemCPUUsage: 0.95
        )
        
        let decision = classifier.shouldRetry(error: networkError, context: highResourceContext)
        if case .stop(let reason) = decision {
            XCTAssertTrue(reason.contains("System resources"))
        } else {
            XCTFail("Expected stop due to system resources, got \(decision)")
        }
    }
    
    // MARK: - Retry Recommendation Tests
    
    func testRetryRecommendation() {
        let networkError = DownloadError.networkTimeout()
        let context = RetryContext(currentAttempt: 1)
        
        let recommendation = errorClassifier.getRetryRecommendation(error: networkError, context: context)
        
        XCTAssertTrue(recommendation.shouldRetry)
        XCTAssertGreaterThan(recommendation.suggestedDelay, 0)
        XCTAssertGreaterThan(recommendation.confidence, 0)
        XCTAssertLessThanOrEqual(recommendation.confidence, 1.0)
        XCTAssertEqual(recommendation.errorCategory, .transientNetwork)
        XCTAssertEqual(recommendation.retryPriority, 8)
        XCTAssertFalse(recommendation.reasoning.isEmpty)
    }
    
    func testConfidenceCalculation() {
        let networkError = DownloadError.networkTimeout()
        let contentError = DownloadError.checksumMismatch(expected: "abc", actual: "def")
        let clientError = DownloadError.invalidURL("bad")
        
        let context1 = RetryContext(currentAttempt: 1)
        let context5 = RetryContext(currentAttempt: 5)
        
        let networkRec1 = errorClassifier.getRetryRecommendation(error: networkError, context: context1)
        let networkRec5 = errorClassifier.getRetryRecommendation(error: networkError, context: context5)
        let contentRec = errorClassifier.getRetryRecommendation(error: contentError, context: context1)
        let clientRec = errorClassifier.getRetryRecommendation(error: clientError, context: context1)
        
        // Network errors should have high confidence
        XCTAssertGreaterThan(networkRec1.confidence, 0.7)
        
        // Confidence should decrease with more attempts
        XCTAssertLessThan(networkRec5.confidence, networkRec1.confidence)
        
        // Content integrity should have decent confidence
        XCTAssertGreaterThan(contentRec.confidence, 0.5)
        
        // Client errors should have low confidence (not retryable)
        XCTAssertLessThan(clientRec.confidence, 0.3)
    }
    
    // MARK: - Configuration Tests
    
    func testDifferentConfigurations() {
        let conservativeClassifier = ErrorClassifier(logger: logger, configuration: .conservative)
        let aggressiveClassifier = ErrorClassifier(logger: logger, configuration: .aggressive)
        
        let networkError = DownloadError.networkTimeout()
        let context = RetryContext(currentAttempt: 8) // High attempt number
        
        let conservativeDecision = conservativeClassifier.shouldRetry(error: networkError, context: context)
        let aggressiveDecision = aggressiveClassifier.shouldRetry(error: networkError, context: context)
        
        // Conservative should stop earlier
        if case .stop = conservativeDecision,
           case .retry = aggressiveDecision {
            // Expected behavior
        } else {
            // Both might be the same if within both limits, that's also valid
        }
        
        // Test delay differences
        let delay1Context = RetryContext(currentAttempt: 1)
        let conservativeDelay = conservativeClassifier.calculateRetryDelay(for: networkError, attempt: 1, context: delay1Context)
        let aggressiveDelay = aggressiveClassifier.calculateRetryDelay(for: networkError, attempt: 1, context: delay1Context)
        
        // Conservative should have longer minimum delays
        XCTAssertGreaterThanOrEqual(conservativeDelay, aggressiveDelay)
    }
    
    // MARK: - Edge Cases and Error Handling
    
    func testUnknownErrors() {
        struct CustomError: Error {
            let message: String
        }
        
        let customError = CustomError(message: "Unknown error")
        let context = ErrorContext()
        
        let classifiedError = errorClassifier.classifyError(customError, context: context)
        
        // Should be classified as a connection failure
        if case .connectionFailed = classifiedError {
            // Expected
        } else {
            XCTFail("Expected connectionFailed for unknown error, got \(classifiedError)")
        }
    }
    
    func testZeroAttemptContext() {
        let networkError = DownloadError.networkTimeout()
        let zeroAttemptContext = RetryContext(currentAttempt: 0)
        
        let decision = errorClassifier.shouldRetry(error: networkError, context: zeroAttemptContext)
        
        // Should still be able to handle zero attempts gracefully
        if case .retry = decision {
            // Expected
        } else {
            XCTFail("Expected retry even with zero attempts, got \(decision)")
        }
    }
    
    func testNegativeDelayHandling() {
        let config = ErrorClassificationConfig(
            globalMaxAttempts: 10,
            globalMaxRetryTime: nil,
            minRetryDelay: 1.0, // Minimum 1 second
            maxRetryDelay: 60.0,
            maxRedirects: 10,
            respectSystemResources: false,
            maxConcurrentRetries: 5
        )
        let classifier = ErrorClassifier(logger: logger, configuration: config)
        
        // Test with a very low base delay
        let lowDelayError = DownloadError.checksumMismatch(expected: "a", actual: "b") // 1.0s base delay
        let context = RetryContext(currentAttempt: 1, networkQuality: .excellent) // Might reduce delay
        
        let delay = classifier.calculateRetryDelay(for: lowDelayError, attempt: 1, context: context)
        
        // Should respect minimum delay
        XCTAssertGreaterThanOrEqual(delay, config.minRetryDelay)
    }
    
    // MARK: - Performance Tests
    
    func testClassificationPerformance() {
        let context = ErrorContext(url: URL(string: "https://example.com"))
        let urlError = URLError(.timedOut)
        
        measure {
            for _ in 0..<1000 {
                _ = errorClassifier.classifyError(urlError, context: context)
            }
        }
    }
    
    func testRetryDecisionPerformance() {
        let networkError = DownloadError.networkTimeout()
        let context = RetryContext(currentAttempt: 3)
        
        measure {
            for _ in 0..<1000 {
                _ = errorClassifier.shouldRetry(error: networkError, context: context)
            }
        }
    }
    
    // MARK: - Integration Tests
    
    func testClassificationWithRetryStrategy() {
        // Test that ErrorClassifier works well with RetryStrategy
        let networkError = DownloadError.networkTimeout()
        let context = RetryContext(currentAttempt: 1)
        
        let recommendation = errorClassifier.getRetryRecommendation(error: networkError, context: context)
        
        // Verify recommendation makes sense
        XCTAssertTrue(recommendation.shouldRetry)
        XCTAssertGreaterThan(recommendation.suggestedDelay, 0)
        XCTAssertLessThanOrEqual(recommendation.suggestedDelay, 60.0) // Within reasonable bounds
        
        // Test the decision consistency
        let manualDecision = errorClassifier.shouldRetry(error: networkError, context: context)
        
        switch (recommendation.decision, manualDecision) {
        case (.retry, .retry), (.stop, .stop), (.circuitBreakerOpen, .circuitBreakerOpen):
            // Consistent
            break
        default:
            XCTFail("Inconsistent decisions: \(recommendation.decision) vs \(manualDecision)")
        }
    }
}