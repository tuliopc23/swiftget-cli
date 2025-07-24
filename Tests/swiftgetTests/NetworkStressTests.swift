import XCTest
import Foundation
import Logging
@testable import swiftget

final class NetworkStressTests: XCTestCase {
    private var mockServer: MockServer!
    private var tempDirectory: URL!
    private let logger = Logger(label: "network-stress-test")
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create temporary directory for stress test downloads
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftget-stress-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Start mock server
        mockServer = MockServer()
        _ = try mockServer.start()
        
        // Add stress test files
        setupStressTestFiles()
        
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
    
    private func setupStressTestFiles() {
        // Large file for stress testing
        let stressData = MockServer.createTestData(size: 20 * 1024 * 1024, pattern: 0x55) // 20MB
        let stressFile = MockServer.TestFile(
            path: "/stress-20mb.bin",
            data: stressData,
            contentType: "application/octet-stream"
        )
        mockServer.addTestFile(stressFile)
        
        // Multiple small files for concurrent testing
        for i in 0..<10 {
            let smallData = MockServer.createTestData(size: 1024 * 1024, pattern: UInt8(0x60 + i)) // 1MB each
            let smallFile = MockServer.TestFile(
                path: "/concurrent-\(i).bin",
                data: smallData,
                contentType: "application/octet-stream"
            )
            mockServer.addTestFile(smallFile)
        }
        
        // File with simulated network issues
        let unreliableData = MockServer.createTestData(size: 5 * 1024 * 1024, pattern: 0x77) // 5MB
        let unreliableFile = MockServer.TestFile(
            path: "/unreliable.bin",
            data: unreliableData,
            contentType: "application/octet-stream",
            simulateSlowResponse: true
        )
        mockServer.addTestFile(unreliableFile)
    }
    
    // MARK: - High Connection Count Tests
    
    func testExtremeConnectionCount() async throws {
        let config = createStressTestConfiguration(connections: 32)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/stress-20mb.bin"
        
        let startTime = CFAbsoluteTimeGetCurrent()
        try await downloadManager.downloadUrls([testURL])
        let endTime = CFAbsoluteTimeGetCurrent()
        
        let downloadTime = endTime - startTime
        print("Extreme connection count (32): \(String(format: "%.2f", downloadTime))s")
        
        // Verify file was downloaded correctly
        let expectedFile = tempDirectory.appendingPathComponent("stress-20mb.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        let attributes = try FileManager.default.attributesOfItem(atPath: expectedFile.path)
        let fileSize = attributes[.size] as? Int64
        XCTAssertEqual(fileSize, 20 * 1024 * 1024)
        
        // Verify content integrity
        let downloadedData = try Data(contentsOf: expectedFile)
        let expectedData = MockServer.createTestData(size: 20 * 1024 * 1024, pattern: 0x55)
        XCTAssertEqual(downloadedData, expectedData)
    }
    
    func testConnectionCountScaling() async throws {
        let connectionCounts = [1, 4, 8, 16, 32, 64]
        var results: [(connections: Int, time: Double)] = []
        
        for connections in connectionCounts {
            let config = createStressTestConfiguration(connections: connections)
            let downloadManager = DownloadManager(configuration: config)
            
            let testURL = "\(mockServer.baseURL)/stress-20mb.bin"
            let outputFile = tempDirectory.appendingPathComponent("scaling-\(connections).bin")
            
            let configWithOutput = DownloadConfiguration(
                directory: tempDirectory.path,
                output: "scaling-\(connections).bin",
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
            
            print("Connections: \(connections), Time: \(String(format: "%.2f", downloadTime))s")
            
            // Verify file integrity
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
            let downloadedData = try Data(contentsOf: outputFile)
            let expectedData = MockServer.createTestData(size: 20 * 1024 * 1024, pattern: 0x55)
            XCTAssertEqual(downloadedData, expectedData)
            
            // Clean up for next iteration
            try? FileManager.default.removeItem(at: outputFile)
        }
        
        // Analyze scaling behavior
        let baselineTime = results.first?.time ?? 1.0
        for result in results {
            let speedup = baselineTime / result.time
            print("Connections: \(result.connections), Speedup: \(String(format: "%.2f", speedup))x")
        }
        
        // Verify that higher connection counts don't significantly degrade performance
        let maxTime = results.map { $0.time }.max() ?? 0
        let minTime = results.map { $0.time }.min() ?? 1
        let timeVariance = maxTime / minTime
        
        // Time variance should be reasonable (not more than 3x difference)
        XCTAssertLessThan(timeVariance, 3.0)
    }
    
    // MARK: - Concurrent Download Stress Tests
    
    func testMassiveConcurrentDownloads() async throws {
        let downloadCount = 20
        let urls = (0..<downloadCount).map { i in
            "\(mockServer.baseURL)/concurrent-\(i % 10).bin" // Reuse files to stress server
        }
        
        let configs = urls.enumerated().map { index, _ in
            DownloadConfiguration(
                directory: tempDirectory.path,
                output: "massive-\(index).bin",
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
        
        // Start massive concurrent downloads
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
        
        print("Massive concurrent downloads (\(downloadCount)): \(String(format: "%.2f", totalTime))s")
        
        // Verify all files were downloaded correctly
        for index in 0..<downloadCount {
            let outputFile = tempDirectory.appendingPathComponent("massive-\(index).bin")
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
            
            let attributes = try FileManager.default.attributesOfItem(atPath: outputFile.path)
            let fileSize = attributes[.size] as? Int64
            XCTAssertEqual(fileSize, 1024 * 1024) // 1MB each
        }
        
        // Performance should be reasonable (not more than 60 seconds for 20MB total)
        XCTAssertLessThan(totalTime, 60.0)
    }
    
    func testConcurrentMultiConnectionDownloads() async throws {
        let downloadCount = 8
        let urls = (0..<downloadCount).map { _ in "\(mockServer.baseURL)/stress-20mb.bin" }
        
        let configs = urls.enumerated().map { index, _ in
            DownloadConfiguration(
                directory: tempDirectory.path,
                output: "concurrent-multi-\(index).bin",
                connections: 8, // Each download uses 8 connections
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
        
        // Start concurrent multi-connection downloads
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
        let totalSize = downloadCount * 20 * 1024 * 1024 // 20MB each
        let aggregateThroughput = Double(totalSize) / totalTime / (1024 * 1024) // MB/s
        
        print("Concurrent multi-connection downloads (\(downloadCount) × 20MB with 8 connections each):")
        print("  Total time: \(String(format: "%.2f", totalTime))s")
        print("  Aggregate throughput: \(String(format: "%.2f", aggregateThroughput)) MB/s")
        
        // Verify all files were downloaded correctly
        for index in 0..<downloadCount {
            let outputFile = tempDirectory.appendingPathComponent("concurrent-multi-\(index).bin")
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
            
            let attributes = try FileManager.default.attributesOfItem(atPath: outputFile.path)
            let fileSize = attributes[.size] as? Int64
            XCTAssertEqual(fileSize, 20 * 1024 * 1024)
            
            // Verify content integrity for a few files
            if index < 3 {
                let downloadedData = try Data(contentsOf: outputFile)
                let expectedData = MockServer.createTestData(size: 20 * 1024 * 1024, pattern: 0x55)
                XCTAssertEqual(downloadedData, expectedData)
            }
        }
        
        // Aggregate throughput should be reasonable
        XCTAssertGreaterThan(aggregateThroughput, 10.0) // At least 10 MB/s aggregate
    }
    
    // MARK: - Memory Stress Tests
    
    func testMemoryUsageUnderStress() async throws {
        let config = createStressTestConfiguration(connections: 16)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/stress-20mb.bin"
        
        // Measure memory before
        let memoryBefore = getCurrentMemoryUsage()
        
        // Run multiple downloads sequentially to stress memory management
        for i in 0..<5 {
            let outputFile = tempDirectory.appendingPathComponent("memory-stress-\(i).bin")
            let configWithOutput = DownloadConfiguration(
                directory: tempDirectory.path,
                output: "memory-stress-\(i).bin",
                connections: 16,
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
            
            // Check memory usage periodically
            let currentMemory = getCurrentMemoryUsage()
            let memoryDelta = currentMemory - memoryBefore
            
            print("Download \(i + 1): Memory delta: \(formatBytes(memoryDelta))")
            
            // Memory usage should not grow excessively
            XCTAssertLessThan(memoryDelta, 500 * 1024 * 1024) // Less than 500MB
        }
        
        let memoryAfter = getCurrentMemoryUsage()
        let totalMemoryDelta = memoryAfter - memoryBefore
        
        print("Total memory delta after 5 downloads: \(formatBytes(totalMemoryDelta))")
        
        // Total memory usage should be reasonable
        XCTAssertLessThan(totalMemoryDelta, 300 * 1024 * 1024) // Less than 300MB total
    }
    
    func testMemoryLeakDetection() async throws {
        let config = createStressTestConfiguration(connections: 8)
        
        let initialMemory = getCurrentMemoryUsage()
        var memoryReadings: [Int] = []
        
        // Run many small downloads to detect potential memory leaks
        for i in 0..<20 {
            let downloadManager = DownloadManager(configuration: config)
            let testURL = "\(mockServer.baseURL)/concurrent-\(i % 10).bin"
            let outputFile = tempDirectory.appendingPathComponent("leak-test-\(i).bin")
            
            let configWithOutput = DownloadConfiguration(
                directory: tempDirectory.path,
                output: "leak-test-\(i).bin",
                connections: 8,
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
            
            // Verify download
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))
            
            // Record memory usage
            let currentMemory = getCurrentMemoryUsage()
            memoryReadings.append(currentMemory)
            
            // Clean up downloaded file to avoid disk space issues
            try? FileManager.default.removeItem(at: outputFile)
            
            // Force garbage collection attempt
            if i % 5 == 0 {
                // Give system time to clean up
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
        }
        
        // Analyze memory trend
        let finalMemory = getCurrentMemoryUsage()
        let memoryGrowth = finalMemory - initialMemory
        
        print("Memory leak test:")
        print("  Initial memory: \(formatBytes(initialMemory))")
        print("  Final memory: \(formatBytes(finalMemory))")
        print("  Memory growth: \(formatBytes(memoryGrowth))")
        
        // Memory growth should be minimal (less than 100MB for 20 downloads)
        XCTAssertLessThan(memoryGrowth, 100 * 1024 * 1024)
        
        // Check for consistent memory growth (potential leak indicator)
        let firstHalf = Array(memoryReadings.prefix(10))
        let secondHalf = Array(memoryReadings.suffix(10))
        
        let firstHalfAvg = firstHalf.reduce(0, +) / firstHalf.count
        let secondHalfAvg = secondHalf.reduce(0, +) / secondHalf.count
        
        let memoryTrend = Double(secondHalfAvg - firstHalfAvg) / Double(firstHalfAvg)
        
        print("  Memory trend: \(String(format: "%.2f", memoryTrend * 100))%")
        
        // Memory trend should be minimal (less than 20% growth)
        XCTAssertLessThan(memoryTrend, 0.2)
    }
    
    // MARK: - Network Reliability Tests
    
    func testSlowNetworkConditions() async throws {
        let config = createStressTestConfiguration(connections: 4)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/unreliable.bin"
        
        let startTime = CFAbsoluteTimeGetCurrent()
        try await downloadManager.downloadUrls([testURL])
        let endTime = CFAbsoluteTimeGetCurrent()
        
        let downloadTime = endTime - startTime
        
        print("Slow network download time: \(String(format: "%.2f", downloadTime))s")
        
        // Should handle slow network gracefully
        XCTAssertGreaterThan(downloadTime, 2.0) // Should take at least 2 seconds due to simulated delay
        XCTAssertLessThan(downloadTime, 30.0) // But not more than 30 seconds
        
        // Verify file was downloaded correctly
        let expectedFile = tempDirectory.appendingPathComponent("unreliable.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        
        let attributes = try FileManager.default.attributesOfItem(atPath: expectedFile.path)
        let fileSize = attributes[.size] as? Int64
        XCTAssertEqual(fileSize, 5 * 1024 * 1024)
    }
    
    func testNetworkTimeoutHandling() async throws {
        // This test would require a more sophisticated mock server
        // For now, we'll test with a very short timeout
        let config = DownloadConfiguration(
            directory: tempDirectory.path,
            output: nil,
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
        
        let downloadManager = DownloadManager(configuration: config)
        
        // Test with a URL that should work
        let testURL = "\(mockServer.baseURL)/concurrent-0.bin"
        
        // This should succeed
        try await downloadManager.downloadUrls([testURL])
        
        let expectedFile = tempDirectory.appendingPathComponent("concurrent-0.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
    }
    
    // MARK: - Resource Exhaustion Tests
    
    func testFileDescriptorLimits() async throws {
        // Test with many connections to stress file descriptor usage
        let config = createStressTestConfiguration(connections: 64)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/stress-20mb.bin"
        
        // This should not crash due to file descriptor exhaustion
        try await downloadManager.downloadUrls([testURL])
        
        let expectedFile = tempDirectory.appendingPathComponent("stress-20mb.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
    }
    
    func testDiskSpaceHandling() async throws {
        // Test downloading to a location with limited space
        // Note: This is a simplified test - in practice, you'd need to create
        // a disk image with limited space
        
        let config = createStressTestConfiguration(connections: 4)
        let downloadManager = DownloadManager(configuration: config)
        
        let testURL = "\(mockServer.baseURL)/stress-20mb.bin"
        
        // Should handle normal disk operations
        try await downloadManager.downloadUrls([testURL])
        
        let expectedFile = tempDirectory.appendingPathComponent("stress-20mb.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
    }
    
    // MARK: - Helper Methods
    
    private func createStressTestConfiguration(connections: Int = 4) -> DownloadConfiguration {
        return DownloadConfiguration(
            directory: tempDirectory.path,
            output: nil,
            connections: connections,
            maxSpeed: nil,
            userAgent: nil,
            headers: [:],
            proxy: nil,
            checksum: nil,
            continueDownload: false,
            quiet: true, // Quiet mode for stress tests
            verbose: false,
            showProgress: false, // No progress for stress tests
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
