import XCTest
import Foundation
import Logging
import CryptoKit
@testable import swiftget

final class PerformanceBenchmarks: XCTestCase {
    private var mockServer: MockServer!
    private var tempDirectory: URL!
    private let logger = Logger(label: "performance-benchmark")
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create temporary directory for benchmark downloads
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftget-benchmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Start mock server
        mockServer = MockServer()
        _ = try mockServer.start()
        
        // Add larger test files for benchmarking
        setupBenchmarkFiles()
        
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
    
    private func setupBenchmarkFiles() {
        // 50MB file for serious benchmarking
        let largeData = MockServer.createTestData(size: 50 * 1024 * 1024, pattern: 0x43) // 50MB of 'C'
        let largeFile = MockServer.TestFile(
            path: "/benchmark-50mb.bin",
            data: largeData,
            contentType: "application/octet-stream"
        )
        mockServer.addTestFile(largeFile)
        
        // 100MB file for stress testing
        let extraLargeData = MockServer.createTestData(size: 100 * 1024 * 1024, pattern: 0x44) // 100MB of 'D'
        let extraLargeFile = MockServer.TestFile(
            path: "/benchmark-100mb.bin",
            data: extraLargeData,
            contentType: "application/octet-stream"
        )
        mockServer.addTestFile(extraLargeFile)
        
        // Patterned data for integrity verification
        let patternedData = MockServer.createPatternedTestData(size: 25 * 1024 * 1024) // 25MB with pattern
        let patternedFile = MockServer.TestFile(
            path: "/benchmark-patterned.bin",
            data: patternedData,
            contentType: "application/octet-stream"
        )
        mockServer.addTestFile(patternedFile)
    }
    
    // MARK: - Memory Usage Benchmarks
    
    func testMemoryUsageDuringDownload() async throws {
        let config = createBenchmarkConfiguration(connections: 1)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/benchmark-50mb.bin"
        
        // Measure memory before download
        let memoryBefore = getCurrentMemoryUsage()
        
        try await downloadManager.downloadUrls([testURL])
        
        // Measure memory after download
        let memoryAfter = getCurrentMemoryUsage()
        let memoryDelta = memoryAfter - memoryBefore
        
        print("Memory usage - Before: \(formatBytes(memoryBefore)), After: \(formatBytes(memoryAfter)), Delta: \(formatBytes(memoryDelta))")
        
        // Verify file was downloaded
        let expectedFile = tempDirectory.appendingPathComponent("benchmark-50mb.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        // Memory usage should be reasonable (< 200MB for 50MB download in CI)
        XCTAssertLessThan(memoryDelta, 200 * 1024 * 1024)
    }
    
    func testMemoryUsageMultiConnection() async throws {
        let config = createBenchmarkConfiguration(connections: 8)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/benchmark-50mb.bin"
        
        // Measure memory before download
        let memoryBefore = getCurrentMemoryUsage()
        
        try await downloadManager.downloadUrls([testURL])
        
        // Measure memory after download
        let memoryAfter = getCurrentMemoryUsage()
        let memoryDelta = memoryAfter - memoryBefore
        
        print("Multi-connection memory usage - Before: \(formatBytes(memoryBefore)), After: \(formatBytes(memoryAfter)), Delta: \(formatBytes(memoryDelta))")
        
        // Verify file was downloaded
        let expectedFile = tempDirectory.appendingPathComponent("benchmark-50mb.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        // Multi-connection should not use significantly more memory
        XCTAssertLessThan(memoryDelta, 300 * 1024 * 1024) // Allow more for multiple connections in CI
    }
    
    // MARK: - Throughput Benchmarks
    
    func testSingleConnectionThroughput() async throws {
        let config = createBenchmarkConfiguration(connections: 1)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/benchmark-50mb.bin"
        
        let startTime = CFAbsoluteTimeGetCurrent()
        try await downloadManager.downloadUrls([testURL])
        let endTime = CFAbsoluteTimeGetCurrent()
        
        let downloadTime = endTime - startTime
        let fileSize = 50 * 1024 * 1024 // 50MB
        let throughput = Double(fileSize) / downloadTime / (1024 * 1024) // MB/s
        
        print("Single connection throughput: \(String(format: "%.2f", throughput)) MB/s")
        
        // Verify reasonable performance (should be > 20 MB/s on localhost)
        XCTAssertGreaterThan(throughput, 5.0) // Lower threshold for CI environments
        
        // Verify file integrity
        let expectedFile = tempDirectory.appendingPathComponent("benchmark-50mb.bin")
        let downloadedData = try Data(contentsOf: expectedFile)
        let expectedData = MockServer.createTestData(size: 50 * 1024 * 1024, pattern: 0x43)
        XCTAssertEqual(downloadedData, expectedData)
    }
    
    func testMultiConnectionThroughput() async throws {
        let connectionCounts = [2, 4, 8, 16]
        var results: [(connections: Int, throughput: Double)] = []
        
        for connections in connectionCounts {
            let config = createBenchmarkConfiguration(connections: connections)
            let downloadManager = DownloadManager(configuration: config)
            
            let testURL = "\(mockServer.baseURL)/benchmark-50mb.bin"
            let outputFile = tempDirectory.appendingPathComponent("benchmark-\(connections)conn.bin")
            
            let configWithOutput = DownloadConfiguration(
                directory: tempDirectory.path,
                output: "benchmark-\(connections)conn.bin",
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
            let fileSize = 50 * 1024 * 1024 // 50MB
            let throughput = Double(fileSize) / downloadTime / (1024 * 1024) // MB/s
            
            results.append((connections: connections, throughput: throughput))
            
            print("Connections: \(connections), Throughput: \(String(format: "%.2f", throughput)) MB/s")
            
            // Verify file integrity
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
            let downloadedData = try Data(contentsOf: outputFile)
            let expectedData = MockServer.createTestData(size: 50 * 1024 * 1024, pattern: 0x43)
            XCTAssertEqual(downloadedData, expectedData)
        }
        
        // Find best performing configuration
        let bestResult = results.max { $0.throughput < $1.throughput }
        print("Best throughput: \(bestResult?.connections ?? 0) connections at \(String(format: "%.2f", bestResult?.throughput ?? 0)) MB/s")
        
        // All configurations should achieve reasonable throughput
        for result in results {
            XCTAssertGreaterThan(result.throughput, 3.0) // Minimum 3 MB/s for CI
        }
    }
    
    // MARK: - Scalability Benchmarks
    
    func testConcurrentDownloadScalability() async throws {
        let downloadCounts = [1, 2, 4, 8]
        
        for downloadCount in downloadCounts {
            let urls = (0..<downloadCount).map { _ in "\(mockServer.baseURL)/benchmark-patterned.bin" }
            
            let configs = urls.enumerated().map { index, _ in
                DownloadConfiguration(
                    directory: tempDirectory.path,
                    output: "concurrent-\(downloadCount)-\(index).bin",
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
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
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
            
            let endTime = CFAbsoluteTimeGetCurrent()
            let totalTime = endTime - startTime
            let totalSize = downloadCount * 25 * 1024 * 1024 // 25MB each
            let aggregateThroughput = Double(totalSize) / totalTime / (1024 * 1024) // MB/s
            
            print("Concurrent downloads: \(downloadCount), Total time: \(String(format: "%.2f", totalTime))s, Aggregate throughput: \(String(format: "%.2f", aggregateThroughput)) MB/s")
            
            // Verify all files were downloaded correctly
            for index in 0..<downloadCount {
                let outputFile = tempDirectory.appendingPathComponent("concurrent-\(downloadCount)-\(index).bin")
                XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
                
                let downloadedData = try Data(contentsOf: outputFile)
                let expectedData = MockServer.createPatternedTestData(size: 25 * 1024 * 1024)
                XCTAssertEqual(downloadedData, expectedData)
            }
            
            // Clean up for next iteration
            for index in 0..<downloadCount {
                let outputFile = tempDirectory.appendingPathComponent("concurrent-\(downloadCount)-\(index).bin")
                try? FileManager.default.removeItem(at: outputFile)
            }
        }
    }
    
    // MARK: - Speed Limiting Accuracy Benchmarks
    
    func testSpeedLimitingAccuracy() async throws {
        let speedLimits = [
            100 * 1024,  // 100 KB/s
            500 * 1024,  // 500 KB/s
            1024 * 1024, // 1 MB/s
            2 * 1024 * 1024 // 2 MB/s
        ]
        
        for maxSpeed in speedLimits {
            let config = createBenchmarkConfiguration(connections: 1, maxSpeed: maxSpeed)
            let downloadManager = DownloadManager(configuration: config)
            
            let testURL = "\(mockServer.baseURL)/benchmark-patterned.bin"
            let outputFile = tempDirectory.appendingPathComponent("speed-limited-\(maxSpeed).bin")
            
            let configWithOutput = DownloadConfiguration(
                directory: tempDirectory.path,
                output: "speed-limited-\(maxSpeed).bin",
                connections: 1,
                maxSpeed: maxSpeed,
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
            let fileSize = 25 * 1024 * 1024 // 25MB
            let actualSpeed = Double(fileSize) / downloadTime // bytes/s
            let expectedSpeed = Double(maxSpeed)
            
            let speedRatio = actualSpeed / expectedSpeed
            
            print("Speed limit: \(formatBytes(maxSpeed))/s, Actual: \(formatBytes(Int(actualSpeed)))/s, Ratio: \(String(format: "%.2f", speedRatio))")
            
            // Speed should be within reasonable bounds (0.5x to 1.5x of limit for CI)
            XCTAssertGreaterThan(speedRatio, 0.5)
            XCTAssertLessThan(speedRatio, 1.5)
            
            // Verify file integrity
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
            let downloadedData = try Data(contentsOf: outputFile)
            let expectedData = MockServer.createPatternedTestData(size: 25 * 1024 * 1024)
            XCTAssertEqual(downloadedData, expectedData)
            
            // Clean up
            try? FileManager.default.removeItem(at: outputFile)
        }
    }
    
    // MARK: - Checksum Performance Benchmarks
    
    func testChecksumPerformance() async throws {
        let algorithms: [(ChecksumAlgorithm, String)] = [
            (.md5, "MD5"),
            (.sha1, "SHA1"),
            (.sha256, "SHA256")
        ]
        
        // Create test data
        let testData = MockServer.createPatternedTestData(size: 10 * 1024 * 1024) // 10MB
        let testFile = MockServer.TestFile(
            path: "/checksum-perf.bin",
            data: testData,
            contentType: "application/octet-stream"
        )
        mockServer.addTestFile(testFile)
        
        for (algorithm, name) in algorithms {
            // Calculate expected hash
            let expectedHash: String
            switch algorithm {
            case .md5:
                expectedHash = Insecure.MD5.hash(data: testData)
                    .compactMap { String(format: "%02x", $0) }.joined()
            case .sha1:
                expectedHash = Insecure.SHA1.hash(data: testData)
                    .compactMap { String(format: "%02x", $0) }.joined()
            case .sha256:
                expectedHash = SHA256.hash(data: testData)
                    .compactMap { String(format: "%02x", $0) }.joined()
            }
            
            let checksumInfo = ChecksumInfo(algorithm: algorithm, hash: expectedHash)
            let config = createBenchmarkConfiguration(connections: 1, checksum: checksumInfo)
            let downloadManager = DownloadManager(configuration: config)
            
            let testURL = "\(mockServer.baseURL)/checksum-perf.bin"
            let outputFile = tempDirectory.appendingPathComponent("checksum-\(name.lowercased()).bin")
            
            let configWithOutput = DownloadConfiguration(
                directory: tempDirectory.path,
                output: "checksum-\(name.lowercased()).bin",
                connections: 1,
                maxSpeed: nil,
                userAgent: nil,
                headers: [:],
                proxy: nil,
                checksum: checksumInfo,
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
            
            let totalTime = endTime - startTime
            let fileSize = 10 * 1024 * 1024 // 10MB
            let throughput = Double(fileSize) / totalTime / (1024 * 1024) // MB/s
            
            print("\(name) checksum verification: \(String(format: "%.2f", totalTime))s, Throughput: \(String(format: "%.2f", throughput)) MB/s")
            
            // Verify file was downloaded and verified
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
            
            // Clean up
            try? FileManager.default.removeItem(at: outputFile)
        }
    }
    
    // MARK: - Large File Stress Test
    
    func testLargeFileDownload() async throws {
        let config = createBenchmarkConfiguration(connections: 8)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/benchmark-100mb.bin"
        
        let memoryBefore = getCurrentMemoryUsage()
        let startTime = CFAbsoluteTimeGetCurrent()
        
        try await downloadManager.downloadUrls([testURL])
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let memoryAfter = getCurrentMemoryUsage()
        
        let downloadTime = endTime - startTime
        let fileSize = 100 * 1024 * 1024 // 100MB
        let throughput = Double(fileSize) / downloadTime / (1024 * 1024) // MB/s
        let memoryDelta = memoryAfter - memoryBefore
        
        print("Large file (100MB) download:")
        print("  Time: \(String(format: "%.2f", downloadTime))s")
        print("  Throughput: \(String(format: "%.2f", throughput)) MB/s")
        print("  Memory delta: \(formatBytes(memoryDelta))")
        
        // Verify reasonable performance
        XCTAssertGreaterThan(throughput, 3.0) // At least 3 MB/s for CI
        XCTAssertLessThan(memoryDelta, 400 * 1024 * 1024) // Less than 400MB memory usage for CI
        
        // Verify file integrity
        let expectedFile = tempDirectory.appendingPathComponent("benchmark-100mb.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        let attributes = try FileManager.default.attributesOfItem(atPath: expectedFile.path)
        let actualSize = attributes[.size] as? Int64
        XCTAssertEqual(actualSize, Int64(fileSize))
    }
    
    // MARK: - Helper Methods
    
    private func createBenchmarkConfiguration(
        connections: Int = 1,
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
            quiet: true, // Quiet mode for benchmarks
            verbose: false,
            showProgress: false, // No progress for benchmarks
            checkCertificate: true,
            extract: false,
            openInFinder: false
        )
    }
    
    private func getCurrentMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(bytes)
        var unitIndex = 0
        
        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        
        if unitIndex == 0 {
            return String(format: "%.0f %@", size, units[unitIndex])
        } else {
            return String(format: "%.1f %@", size, units[unitIndex])
        }
    }
}
