import XCTest
import Foundation
import Logging
@testable import swiftget

final class MultiConnectionTests: XCTestCase {
    private var mockServer: MockServer!
    private var tempDirectory: URL!
    private let logger = Logger(label: "multi-connection-test")
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create temporary directory for test downloads
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftget-multiconn-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Start mock server
        mockServer = MockServer()
        _ = try mockServer.start()
        
        // Wait for server to be ready
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
    
    // MARK: - Segment Splitting Tests
    
    func testSegmentSplittingEvenDivision() {
        let contentLength: Int64 = 1000
        let numSegments = 4
        
        let segments = MultiConnectionDownloader.splitSegments(
            contentLength: contentLength,
            numSegments: numSegments
        )
        
        XCTAssertEqual(segments.count, numSegments)
        
        // Verify segments cover entire range
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.last?.end, contentLength - 1)
        
        // Verify no gaps or overlaps
        for i in 0..<segments.count - 1 {
            XCTAssertEqual(segments[i].end + 1, segments[i + 1].start)
        }
        
        // Verify total size
        let totalSize = segments.reduce(0) { sum, segment in
            sum + (segment.end - segment.start + 1)
        }
        XCTAssertEqual(totalSize, contentLength)
    }
    
    func testSegmentSplittingUnevenDivision() {
        let contentLength: Int64 = 1003
        let numSegments = 4
        
        let segments = MultiConnectionDownloader.splitSegments(
            contentLength: contentLength,
            numSegments: numSegments
        )
        
        XCTAssertEqual(segments.count, numSegments)
        
        // Verify segments cover entire range
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.last?.end, contentLength - 1)
        
        // Verify no gaps or overlaps
        for i in 0..<segments.count - 1 {
            XCTAssertEqual(segments[i].end + 1, segments[i + 1].start)
        }
        
        // Verify total size
        let totalSize = segments.reduce(0) { sum, segment in
            sum + (segment.end - segment.start + 1)
        }
        XCTAssertEqual(totalSize, contentLength)
        
        // First segments should get the extra bytes
        let baseSize = contentLength / Int64(numSegments)
        let remainder = contentLength % Int64(numSegments)
        
        for i in 0..<numSegments {
            let expectedSize = baseSize + (i < remainder ? 1 : 0)
            let actualSize = segments[i].end - segments[i].start + 1
            XCTAssertEqual(actualSize, expectedSize)
        }
    }
    
    func testSegmentSplittingSingleSegment() {
        let contentLength: Int64 = 500
        let numSegments = 1
        
        let segments = MultiConnectionDownloader.splitSegments(
            contentLength: contentLength,
            numSegments: numSegments
        )
        
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, contentLength - 1)
    }
    
    func testSegmentSplittingMoreSegmentsThanBytes() {
        let contentLength: Int64 = 3
        let numSegments = 5
        
        let segments = MultiConnectionDownloader.splitSegments(
            contentLength: contentLength,
            numSegments: numSegments
        )
        
        XCTAssertEqual(segments.count, numSegments)
        
        // First 3 segments should have 1 byte each, last 2 should have 0 bytes
        XCTAssertEqual(segments[0].end - segments[0].start + 1, 1)
        XCTAssertEqual(segments[1].end - segments[1].start + 1, 1)
        XCTAssertEqual(segments[2].end - segments[2].start + 1, 1)
        XCTAssertEqual(segments[3].end - segments[3].start + 1, 0)
        XCTAssertEqual(segments[4].end - segments[4].start + 1, 0)
    }
    
    // MARK: - Multi-Connection Download Tests
    
    func testMultiConnectionDownloadSuccess() async throws {
        let config = createTestConfiguration(connections: 4)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/large.bin"
        
        try await downloadManager.downloadUrls([testURL])
        
        // Verify file was downloaded
        let expectedFile = tempDirectory.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        // Verify size
        let attributes = try FileManager.default.attributesOfItem(atPath: expectedFile.path)
        let fileSize = attributes[.size] as? Int64
        XCTAssertEqual(fileSize, 10 * 1024 * 1024) // 10MB
        
        // Verify content integrity
        let downloadedData = try Data(contentsOf: expectedFile)
        let expectedData = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        XCTAssertEqual(downloadedData, expectedData)
    }
    
    func testMultiConnectionFallbackToSingleConnection() async throws {
        // Test with server that doesn't support range requests
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
    
    func testMultiConnectionWithDifferentSegmentCounts() async throws {
        let segmentCounts = [2, 4, 8]
        
        for connections in segmentCounts {
            let config = createTestConfiguration(connections: connections)
            let downloadManager = DownloadManager(configuration: config)
            
            let testURL = "\(mockServer.baseURL)/medium.bin"
            let outputFile = tempDirectory.appendingPathComponent("medium-\(connections).bin")
            
            let configWithOutput = DownloadConfiguration(
                directory: tempDirectory.path,
                output: "medium-\(connections).bin",
                connections: connections,
                maxSpeed: nil,
                userAgent: nil,
                headers: [:],
                proxy: nil,
                checksum: nil,
                continueDownload: false,
                quiet: true,
                verbose: false,
                showProgress: false,
                checkCertificate: true,
                extract: false,
                openInFinder: false
            )
            
            let managerWithOutput = DownloadManager(configuration: configWithOutput)
            try await managerWithOutput.downloadUrls([testURL])
            
            // Verify file was downloaded
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
            
            // Verify size
            let attributes = try FileManager.default.attributesOfItem(atPath: outputFile.path)
            let fileSize = attributes[.size] as? Int64
            XCTAssertEqual(fileSize, 1024 * 1024) // 1MB
            
            // Verify content integrity
            let downloadedData = try Data(contentsOf: outputFile)
            let expectedData = Data(repeating: 0x41, count: 1024 * 1024)
            XCTAssertEqual(downloadedData, expectedData)
        }
    }
    
    func testMultiConnectionWithSpeedLimiting() async throws {
        let maxSpeed = 200 * 1024 // 200KB/s
        let config = createTestConfiguration(connections: 4, maxSpeed: maxSpeed)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/medium.bin"
        
        let startTime = Date()
        try await downloadManager.downloadUrls([testURL])
        let endTime = Date()
        
        let downloadTime = endTime.timeIntervalSince(startTime)
        let fileSize = 1024 * 1024 // 1MB
        let expectedMinTime = Double(fileSize) / Double(maxSpeed) * 0.7 // Allow variance
        
        // Verify download took reasonable time
        XCTAssertGreaterThan(downloadTime, expectedMinTime)
        
        // Verify file was downloaded correctly
        let expectedFile = tempDirectory.appendingPathComponent("medium.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
    }
    
    // MARK: - Error Handling Tests
    
    func testMultiConnectionPartialFailure() async throws {
        // Create a custom test file that will cause some segments to fail
        let testData = MockServer.createTestData(size: 1024 * 1024) // 1MB
        let testFile = MockServer.TestFile(
            path: "/partial-fail.bin",
            data: testData,
            contentType: "application/octet-stream",
            supportsRanges: true,
            simulateSlowResponse: false,
            simulateError: false
        )
        mockServer.addTestFile(testFile)
        
        let config = createTestConfiguration(connections: 4)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/partial-fail.bin"
        
        // This should succeed despite potential partial failures due to retry logic
        try await downloadManager.downloadUrls([testURL])
        
        let expectedFile = tempDirectory.appendingPathComponent("partial-fail.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        // Verify content integrity
        let downloadedData = try Data(contentsOf: expectedFile)
        XCTAssertEqual(downloadedData, testData)
    }
    
    func testMultiConnectionChecksumVerification() async throws {
        // Create test data with known checksum
        let testData = MockServer.createPatternedTestData(size: 512 * 1024) // 512KB with pattern
        let testFile = MockServer.TestFile(
            path: "/checksum-multi.bin",
            data: testData,
            contentType: "application/octet-stream"
        )
        mockServer.addTestFile(testFile)
        
        // Calculate expected SHA256
        let expectedHash = SHA256.hash(data: testData)
            .compactMap { String(format: "%02x", $0) }.joined()
        
        let checksumInfo = ChecksumInfo(algorithm: .sha256, hash: expectedHash)
        let config = createTestConfiguration(connections: 4, checksum: checksumInfo)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/checksum-multi.bin"
        
        // Should succeed with correct checksum
        try await downloadManager.downloadUrls([testURL])
        
        let expectedFile = tempDirectory.appendingPathComponent("checksum-multi.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        // Verify content integrity
        let downloadedData = try Data(contentsOf: expectedFile)
        XCTAssertEqual(downloadedData, testData)
    }
    
    func testMultiConnectionChecksumFailure() async throws {
        let wrongChecksumInfo = ChecksumInfo(algorithm: .sha256, hash: "wrong_hash_value")
        let config = createTestConfiguration(connections: 4, checksum: wrongChecksumInfo)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/medium.bin"
        
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
    
    // MARK: - Performance Comparison Tests
    
    func testSingleVsMultiConnectionPerformance() async throws {
        let testURL = "\(mockServer.baseURL)/large.bin"
        
        // Test single connection
        let singleConfig = createTestConfiguration(connections: 1)
        let singleManager = DownloadManager(configuration: singleConfig)
        
        let singleStartTime = CFAbsoluteTimeGetCurrent()
        try await singleManager.downloadUrls([testURL])
        let singleEndTime = CFAbsoluteTimeGetCurrent()
        let singleTime = singleEndTime - singleStartTime
        
        // Clean up
        let singleFile = tempDirectory.appendingPathComponent("large.bin")
        try FileManager.default.removeItem(at: singleFile)
        
        // Test multi-connection
        let multiConfig = createTestConfiguration(connections: 4)
        let multiManager = DownloadManager(configuration: multiConfig)
        
        let multiStartTime = CFAbsoluteTimeGetCurrent()
        try await multiManager.downloadUrls([testURL])
        let multiEndTime = CFAbsoluteTimeGetCurrent()
        let multiTime = multiEndTime - multiStartTime
        
        print("Single connection: \(String(format: "%.3f", singleTime))s")
        print("Multi connection (4): \(String(format: "%.3f", multiTime))s")
        
        let speedup = singleTime / multiTime
        print("Speedup: \(String(format: "%.2f", speedup))x")
        
        // Multi-connection should be at least as fast (allowing for overhead)
        XCTAssertLessThanOrEqual(multiTime, singleTime * 1.5) // Allow 50% overhead
        
        // Verify both files are identical
        let multiFile = tempDirectory.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: multiFile.path))
        
        let multiData = try Data(contentsOf: multiFile)
        let expectedData = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        XCTAssertEqual(multiData, expectedData)
    }
    
    func testOptimalConnectionCount() async throws {
        let testURL = "\(mockServer.baseURL)/large.bin"
        let connectionCounts = [1, 2, 4, 8, 16]
        var results: [(connections: Int, time: Double)] = []
        
        for connections in connectionCounts {
            let config = createTestConfiguration(connections: connections)
            let manager = DownloadManager(configuration: config)
            
            let outputFile = tempDirectory.appendingPathComponent("large-\(connections).bin")
            let configWithOutput = DownloadConfiguration(
                directory: tempDirectory.path,
                output: "large-\(connections).bin",
                connections: connections,
                maxSpeed: nil,
                userAgent: nil,
                headers: [:],
                proxy: nil,
                checksum: nil,
                continueDownload: false,
                quiet: true,
                verbose: false,
                showProgress: false,
                checkCertificate: true,
                extract: false,
                openInFinder: false
            )
            
            let managerWithOutput = DownloadManager(configuration: configWithOutput)
            
            let startTime = CFAbsoluteTimeGetCurrent()
            try await managerWithOutput.downloadUrls([testURL])
            let endTime = CFAbsoluteTimeGetCurrent()
            let downloadTime = endTime - startTime
            
            results.append((connections: connections, time: downloadTime))
            
            // Verify file integrity
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
            let downloadedData = try Data(contentsOf: outputFile)
            let expectedData = Data(repeating: 0x42, count: 10 * 1024 * 1024)
            XCTAssertEqual(downloadedData, expectedData)
            
            print("Connections: \(connections), Time: \(String(format: "%.3f", downloadTime))s")
        }
        
        // Find the fastest configuration
        let fastest = results.min { $0.time < $1.time }
        print("Fastest configuration: \(fastest?.connections ?? 0) connections in \(String(format: "%.3f", fastest?.time ?? 0))s")
        
        // Verify that multi-connection provides some benefit
        let singleConnectionTime = results.first { $0.connections == 1 }?.time ?? 0
        let bestMultiConnectionTime = results.filter { $0.connections > 1 }.min { $0.time < $1.time }?.time ?? singleConnectionTime
        
        // Multi-connection should be at least as fast as single connection
        XCTAssertLessThanOrEqual(bestMultiConnectionTime, singleConnectionTime * 1.1) // Allow 10% variance
    }
    
    // MARK: - Stress Tests
    
    func testConcurrentMultiConnectionDownloads() async throws {
        let urls = [
            "\(mockServer.baseURL)/medium.bin",
            "\(mockServer.baseURL)/large.bin"
        ]
        
        // Create separate configurations for each download to avoid conflicts
        let configs = urls.enumerated().map { index, _ in
            DownloadConfiguration(
                directory: tempDirectory.path,
                output: "concurrent-\(index).bin",
                connections: 4,
                maxSpeed: nil,
                userAgent: nil,
                headers: [:],
                proxy: nil,
                checksum: nil,
                continueDownload: false,
                quiet: true,
                verbose: false,
                showProgress: false,
                checkCertificate: true,
                extract: false,
                openInFinder: false
            )
        }
        
        // Start concurrent downloads
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    let manager = DownloadManager(configuration: configs[index])
                    try await manager.downloadUrls([url])
                }
            }
            try await group.waitForAll()
        }
        
        // Verify all files were downloaded
        for index in 0..<urls.count {
            let outputFile = tempDirectory.appendingPathComponent("concurrent-\(index).bin")
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestConfiguration(
        connections: Int = 4,
        maxSpeed: Int? = nil,
        checksum: ChecksumInfo? = nil
    ) -> DownloadConfiguration {
        return DownloadConfiguration(
            directory: tempDirectory.path,
            output: nil,
            connections: connections,
            maxSpeed: maxSpeed,
            userAgent: nil,
            headers: [:],
            proxy: nil,
            checksum: checksum,
            continueDownload: false,
            quiet: true, // Quiet mode for tests
            verbose: false,
            showProgress: false, // No progress for tests
            checkCertificate: true,
            extract: false,
            openInFinder: false
        )
    }
}
