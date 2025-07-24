import XCTest
import Foundation
import Logging
import CryptoKit
@testable import swiftget

final class IntegrationTests: XCTestCase {
    private var mockServer: MockServer!
    private var tempDirectory: URL!
    private let logger = Logger(label: "integration-test")
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create temporary directory for test downloads
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftget-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Start mock server
        mockServer = MockServer()
        _ = try mockServer.start()
        
        // Wait a bit for server to be ready
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
    }
    
    override func tearDown() async throws {
        mockServer?.stop()
        
        // Clean up temporary directory
        if let tempDirectory = tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        
        try await super.tearDown()
    }
    
    // MARK: - Basic Download Tests
    
    func testBasicHTTPDownload() async throws {
        let config = createTestConfiguration()
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/small.txt"
        
        try await downloadManager.downloadUrls([testURL])
        
        // Verify file was downloaded
        let expectedFile = tempDirectory.appendingPathComponent("small.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        // Verify content
        let downloadedData = try Data(contentsOf: expectedFile)
        let expectedContent = "Hello, SwiftGet! This is a small test file."
        XCTAssertEqual(String(data: downloadedData, encoding: .utf8), expectedContent)
    }
    
    func testLargeFileDownload() async throws {
        let config = createTestConfiguration()
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/medium.bin"
        
        try await downloadManager.downloadUrls([testURL])
        
        // Verify file was downloaded
        let expectedFile = tempDirectory.appendingPathComponent("medium.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        // Verify size (1MB)
        let attributes = try FileManager.default.attributesOfItem(atPath: expectedFile.path)
        let fileSize = attributes[.size] as? Int64
        XCTAssertEqual(fileSize, 1024 * 1024)
    }
    
    func testCustomOutputFilename() async throws {
        let config = createTestConfiguration(output: "custom-name.txt")
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/small.txt"
        
        try await downloadManager.downloadUrls([testURL])
        
        // Verify file was downloaded with custom name
        let expectedFile = tempDirectory.appendingPathComponent("custom-name.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
    }
    
    // MARK: - Multi-Connection Download Tests
    
    func testMultiConnectionDownload() async throws {
        let config = createTestConfiguration(connections: 4)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/large.bin"
        
        try await downloadManager.downloadUrls([testURL])
        
        // Verify file was downloaded
        let expectedFile = tempDirectory.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        // Verify size (10MB)
        let attributes = try FileManager.default.attributesOfItem(atPath: expectedFile.path)
        let fileSize = attributes[.size] as? Int64
        XCTAssertEqual(fileSize, 10 * 1024 * 1024)
        
        // Verify content integrity
        let downloadedData = try Data(contentsOf: expectedFile)
        let expectedData = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        XCTAssertEqual(downloadedData, expectedData)
    }
    
    func testMultiConnectionFallback() async throws {
        // Test fallback to single connection when server doesn't support ranges
        let config = createTestConfiguration(connections: 4)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/no-ranges.txt"
        
        try await downloadManager.downloadUrls([testURL])
        
        // Verify file was downloaded despite no range support
        let expectedFile = tempDirectory.appendingPathComponent("no-ranges.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        let downloadedData = try Data(contentsOf: expectedFile)
        let expectedContent = "This server doesn't support range requests."
        XCTAssertEqual(String(data: downloadedData, encoding: .utf8), expectedContent)
    }
    
    // MARK: - Resume Download Tests
    
    func testResumeDownload() async throws {
        let config = createTestConfiguration()
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/medium.bin"
        let outputFile = tempDirectory.appendingPathComponent("medium.bin")
        
        // Create partial file (first 512KB)
        let partialData = Data(repeating: 0x41, count: 512 * 1024)
        try partialData.write(to: outputFile)
        
        // Now resume the download
        let resumeConfig = createTestConfiguration(continueDownload: true)
        let resumeManager = DownloadManager(configuration: resumeConfig)
        
        try await resumeManager.downloadUrls([testURL])
        
        // Verify complete file
        let attributes = try FileManager.default.attributesOfItem(atPath: outputFile.path)
        let fileSize = attributes[.size] as? Int64
        XCTAssertEqual(fileSize, 1024 * 1024)
        
        // Verify content integrity
        let downloadedData = try Data(contentsOf: outputFile)
        let expectedData = Data(repeating: 0x41, count: 1024 * 1024)
        XCTAssertEqual(downloadedData, expectedData)
    }
    
    // MARK: - Checksum Verification Tests
    
    func testChecksumVerification() async throws {
        // Create test data with known checksum
        let testData = Data("Test data for checksum verification".utf8)
        let testFile = MockServer.TestFile(
            path: "/checksum-test.txt",
            data: testData,
            contentType: "text/plain"
        )
        mockServer.addTestFile(testFile)
        
        // Calculate expected SHA256
        let expectedHash = SHA256.hash(data: testData)
            .compactMap { String(format: "%02x", $0) }.joined()
        
        let checksumInfo = ChecksumInfo(algorithm: .sha256, hash: expectedHash)
        let config = createTestConfiguration(checksum: checksumInfo)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/checksum-test.txt"
        
        // Should succeed with correct checksum
        try await downloadManager.downloadUrls([testURL])
        
        let expectedFile = tempDirectory.appendingPathComponent("checksum-test.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
    }
    
    func testChecksumVerificationFailure() async throws {
        let wrongChecksumInfo = ChecksumInfo(algorithm: .sha256, hash: "wrong_hash")
        let config = createTestConfiguration(checksum: wrongChecksumInfo)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/small.txt"
        
        // Should throw checksum mismatch error
        do {
            try await downloadManager.downloadUrls([testURL])
            XCTFail("Expected checksum verification to fail")
        } catch let error as DownloadError {
            switch error {
            case .checksumMismatch:
                // Expected error
                break
            default:
                XCTFail("Expected checksum mismatch error, got: \(error)")
            }
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testInvalidURL() async throws {
        let config = createTestConfiguration()
        let downloadManager = DownloadManager(configuration: config)
        
        // Should handle invalid URL gracefully
        try await downloadManager.downloadUrls(["not-a-valid-url"])
        
        // No file should be created
        let files = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty)
    }
    
    func testServerError() async throws {
        let config = createTestConfiguration()
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/error.txt"
        
        // Should handle server error gracefully
        try await downloadManager.downloadUrls([testURL])
        
        // No file should be created
        let files = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty)
    }
    
    func testFileNotFound() async throws {
        let config = createTestConfiguration()
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/nonexistent.txt"
        
        // Should handle 404 gracefully
        try await downloadManager.downloadUrls([testURL])
        
        // No file should be created
        let files = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty)
    }
    
    // MARK: - Speed Limiting Tests
    
    func testSpeedLimiting() async throws {
        let maxSpeed = 100 * 1024 // 100KB/s
        let config = createTestConfiguration(maxSpeed: maxSpeed)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/medium.bin"
        
        let startTime = Date()
        try await downloadManager.downloadUrls([testURL])
        let endTime = Date()
        
        let downloadTime = endTime.timeIntervalSince(startTime)
        let fileSize = 1024 * 1024 // 1MB
        let expectedMinTime = Double(fileSize) / Double(maxSpeed) * 0.8 // Allow 20% variance
        
        // Verify download took reasonable time (accounting for overhead)
        XCTAssertGreaterThan(downloadTime, expectedMinTime)
        
        // Verify file was downloaded correctly
        let expectedFile = tempDirectory.appendingPathComponent("medium.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
    }
    
    // MARK: - Multiple URLs Tests
    
    func testMultipleURLDownload() async throws {
        let config = createTestConfiguration()
        let downloadManager = DownloadManager(configuration: config)
        
        let testURLs = [
            "\(mockServer.baseURL)/small.txt",
            "\(mockServer.baseURL)/medium.bin"
        ]
        
        try await downloadManager.downloadUrls(testURLs)
        
        // Verify both files were downloaded
        let smallFile = tempDirectory.appendingPathComponent("small.txt")
        let mediumFile = tempDirectory.appendingPathComponent("medium.bin")
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: smallFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediumFile.path))
    }
    
    // MARK: - Configuration Tests
    
    func testCustomHeaders() async throws {
        let customHeaders = ["X-Test-Header": "test-value"]
        let config = createTestConfiguration(headers: customHeaders)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/small.txt"
        
        // This test mainly verifies no errors occur with custom headers
        try await downloadManager.downloadUrls([testURL])
        
        let expectedFile = tempDirectory.appendingPathComponent("small.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
    }
    
    func testCustomUserAgent() async throws {
        let customUserAgent = "SwiftGet-Test/1.0"
        let config = createTestConfiguration(userAgent: customUserAgent)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/small.txt"
        
        try await downloadManager.downloadUrls([testURL])
        
        let expectedFile = tempDirectory.appendingPathComponent("small.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
    }
    
    // MARK: - Helper Methods
    
    private func createTestConfiguration(
        output: String? = nil,
        connections: Int = 1,
        maxSpeed: Int? = nil,
        userAgent: String? = nil,
        headers: [String: String] = [:],
        checksum: ChecksumInfo? = nil,
        continueDownload: Bool = false
    ) -> DownloadConfiguration {
        return DownloadConfiguration(
            directory: tempDirectory.path,
            output: output,
            connections: connections,
            maxSpeed: maxSpeed,
            userAgent: userAgent,
            headers: headers,
            proxy: nil,
            checksum: checksum,
            continueDownload: continueDownload,
            quiet: true, // Quiet mode for tests
            verbose: false,
            showProgress: false, // No progress for tests
            checkCertificate: true,
            extract: false,
            openInFinder: false
        )
    }
}

// MARK: - Performance Tests

extension IntegrationTests {
    func testDownloadPerformance() async throws {
        let config = createTestConfiguration()
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/large.bin"
        
        // Measure download time
        let startTime = CFAbsoluteTimeGetCurrent()
        try await downloadManager.downloadUrls([testURL])
        let endTime = CFAbsoluteTimeGetCurrent()
        
        let downloadTime = endTime - startTime
        let fileSize = 10 * 1024 * 1024 // 10MB
        let throughput = Double(fileSize) / downloadTime / (1024 * 1024) // MB/s
        
        print("Download performance: \(String(format: "%.2f", throughput)) MB/s")
        
        // Verify reasonable performance (should be > 10 MB/s on localhost)
        XCTAssertGreaterThan(throughput, 10.0)
    }
    
    func testMultiConnectionPerformance() async throws {
        let singleConfig = createTestConfiguration(connections: 1)
        let multiConfig = createTestConfiguration(connections: 4)
        
        let testURL = "\(mockServer.baseURL)/large.bin"
        
        // Test single connection
        let singleStartTime = CFAbsoluteTimeGetCurrent()
        let singleManager = DownloadManager(configuration: singleConfig)
        try await singleManager.downloadUrls([testURL])
        let singleEndTime = CFAbsoluteTimeGetCurrent()
        let singleTime = singleEndTime - singleStartTime
        
        // Clean up
        let singleFile = tempDirectory.appendingPathComponent("large.bin")
        try FileManager.default.removeItem(at: singleFile)
        
        // Test multi-connection
        let multiStartTime = CFAbsoluteTimeGetCurrent()
        let multiManager = DownloadManager(configuration: multiConfig)
        try await multiManager.downloadUrls([testURL])
        let multiEndTime = CFAbsoluteTimeGetCurrent()
        let multiTime = multiEndTime - multiStartTime
        
        print("Single connection time: \(String(format: "%.2f", singleTime))s")
        print("Multi connection time: \(String(format: "%.2f", multiTime))s")
        
        // Multi-connection should be faster or at least not significantly slower
        // (On localhost, the difference might be minimal due to no network latency)
        XCTAssertLessThanOrEqual(multiTime, singleTime * 1.2) // Allow 20% variance
    }
}
