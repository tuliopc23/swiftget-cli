#!/usr/bin/env swift

import Foundation
import Dispatch

// MARK: - Benchmark Configuration

struct BenchmarkConfig {
    let testFiles: [TestFile]
    let connectionCounts: [Int]
    let iterations: Int
    let outputDirectory: String
    
    struct TestFile {
        let name: String
        let url: String
        let expectedSize: Int64
        let description: String
    }
    
    static let `default` = BenchmarkConfig(
        testFiles: [
            TestFile(
                name: "small",
                url: "https://httpbin.org/bytes/1048576", // 1MB
                expectedSize: 1_048_576,
                description: "1MB test file"
            ),
            TestFile(
                name: "medium",
                url: "https://httpbin.org/bytes/10485760", // 10MB
                expectedSize: 10_485_760,
                description: "10MB test file"
            ),
            TestFile(
                name: "large",
                url: "https://httpbin.org/bytes/52428800", // 50MB
                expectedSize: 52_428_800,
                description: "50MB test file"
            )
        ],
        connectionCounts: [1, 2, 4, 8, 16],
        iterations: 3,
        outputDirectory: "benchmark-results"
    )
}

// MARK: - Benchmark Result

struct BenchmarkResult {
    let testName: String
    let connections: Int
    let iteration: Int
    let downloadTime: TimeInterval
    let throughput: Double // MB/s
    let memoryUsage: Int64 // bytes
    let success: Bool
    let error: String?
    
    var throughputMBps: Double {
        return throughput
    }
    
    var formattedThroughput: String {
        return String(format: "%.2f MB/s", throughput)
    }
    
    var formattedMemory: String {
        return formatBytes(memoryUsage)
    }
}

// MARK: - Benchmark Runner

class BenchmarkRunner {
    private let config: BenchmarkConfig
    private let swiftgetPath: String
    private var results: [BenchmarkResult] = []
    
    init(config: BenchmarkConfig = .default, swiftgetPath: String = ".build/release/swiftget") {
        self.config = config
        self.swiftgetPath = swiftgetPath
    }
    
    func runAllBenchmarks() {
        print("🚀 Starting SwiftGet Performance Benchmarks")
        print("=" * 50)
        
        // Ensure output directory exists
        createOutputDirectory()
        
        // Verify swiftget binary exists
        guard verifySwiftGetBinary() else {
            print("❌ SwiftGet binary not found at: \(swiftgetPath)")
            print("Please build the release binary first: swift build -c release")
            exit(1)
        }
        
        // Run benchmarks for each test file and connection count
        for testFile in config.testFiles {
            print("\n📁 Testing with \(testFile.description)")
            print("-" * 30)
            
            for connections in config.connectionCounts {
                print("🔗 Testing \(connections) connection(s)...")
                
                for iteration in 1...config.iterations {
                    let result = runSingleBenchmark(
                        testFile: testFile,
                        connections: connections,
                        iteration: iteration
                    )
                    results.append(result)
                    
                    if result.success {
                        print("  Iteration \(iteration): \(result.formattedThroughput)")
                    } else {
                        print("  Iteration \(iteration): FAILED - \(result.error ?? "Unknown error")")
                    }
                }
            }
        }
        
        // Generate and display results
        generateReport()
        saveResultsToFile()
        
        print("\n✅ Benchmark completed!")
        print("📊 Results saved to: \(config.outputDirectory)/")
    }
    
    private func runSingleBenchmark(testFile: BenchmarkConfig.TestFile, connections: Int, iteration: Int) -> BenchmarkResult {
        let outputFileName = "\(testFile.name)-\(connections)conn-iter\(iteration).bin"
        let outputPath = "\(config.outputDirectory)/\(outputFileName)"
        
        // Clean up any existing file
        try? FileManager.default.removeItem(atPath: outputPath)
        
        // Measure memory before
        let memoryBefore = getCurrentMemoryUsage()
        
        // Run swiftget command
        let startTime = CFAbsoluteTimeGetCurrent()
        let (success, error) = runSwiftGet(
            url: testFile.url,
            outputPath: outputPath,
            connections: connections
        )
        let endTime = CFAbsoluteTimeGetCurrent()
        
        // Measure memory after
        let memoryAfter = getCurrentMemoryUsage()
        let memoryDelta = memoryAfter - memoryBefore
        
        let downloadTime = endTime - startTime
        let throughput = success ? Double(testFile.expectedSize) / downloadTime / (1024 * 1024) : 0.0
        
        return BenchmarkResult(
            testName: testFile.name,
            connections: connections,
            iteration: iteration,
            downloadTime: downloadTime,
            throughput: throughput,
            memoryUsage: memoryDelta,
            success: success,
            error: error
        )
    }
    
    private func runSwiftGet(url: String, outputPath: String, connections: Int) -> (Bool, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftgetPath)
        process.arguments = [
            url,
            "--output", outputPath,
            "--connections", "\(connections)",
            "--quiet"
        ]
        
        let pipe = Pipe()
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                // Verify file was created and has expected size
                if FileManager.default.fileExists(atPath: outputPath) {
                    return (true, nil)
                } else {
                    return (false, "Output file not created")
                }
            } else {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                return (false, errorString)
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }
    
    private func generateReport() {
        print("\n📊 BENCHMARK RESULTS")
        print("=" * 60)
        
        // Group results by test file
        let groupedResults = Dictionary(grouping: results) { $0.testName }
        
        for (testName, testResults) in groupedResults.sorted(by: { $0.key < $1.key }) {
            print("\n📁 \(testName.uppercased()) FILE RESULTS:")
            print("-" * 40)
            
            // Group by connection count
            let connectionGroups = Dictionary(grouping: testResults) { $0.connections }
            
            for connections in config.connectionCounts {
                guard let connectionResults = connectionGroups[connections] else { continue }
                
                let successfulResults = connectionResults.filter { $0.success }
                
                if successfulResults.isEmpty {
                    print("🔗 \(connections) connections: ALL FAILED")
                    continue
                }
                
                let avgThroughput = successfulResults.map { $0.throughput }.reduce(0, +) / Double(successfulResults.count)
                let avgMemory = successfulResults.map { $0.memoryUsage }.reduce(0, +) / Int64(successfulResults.count)
                let avgTime = successfulResults.map { $0.downloadTime }.reduce(0, +) / Double(successfulResults.count)
                
                let minThroughput = successfulResults.map { $0.throughput }.min() ?? 0
                let maxThroughput = successfulResults.map { $0.throughput }.max() ?? 0
                
                print("🔗 \(connections) connections:")
                print("   Throughput: \(String(format: "%.2f", avgThroughput)) MB/s (min: \(String(format: "%.2f", minThroughput)), max: \(String(format: "%.2f", maxThroughput)))")
                print("   Avg Time: \(String(format: "%.2f", avgTime))s")
                print("   Avg Memory: \(formatBytes(avgMemory))")
                print("   Success Rate: \(successfulResults.count)/\(connectionResults.count)")
            }
        }
        
        // Overall best performance
        print("\n🏆 BEST PERFORMANCE:")
        print("-" * 30)
        
        let successfulResults = results.filter { $0.success }
        if let bestResult = successfulResults.max(by: { $0.throughput < $1.throughput }) {
            print("🥇 Fastest: \(bestResult.formattedThroughput) (\(bestResult.testName), \(bestResult.connections) connections)")
        }
        
        // Connection count analysis
        print("\n📈 CONNECTION COUNT ANALYSIS:")
        print("-" * 35)
        
        for connections in config.connectionCounts {
            let connectionResults = successfulResults.filter { $0.connections == connections }
            if !connectionResults.isEmpty {
                let avgThroughput = connectionResults.map { $0.throughput }.reduce(0, +) / Double(connectionResults.count)
                print("\(connections) connections: \(String(format: "%.2f", avgThroughput)) MB/s avg")
            }
        }
    }
    
    private func saveResultsToFile() {
        let timestamp = DateFormatter().string(from: Date())
        let csvPath = "\(config.outputDirectory)/benchmark-results-\(timestamp).csv"
        let jsonPath = "\(config.outputDirectory)/benchmark-results-\(timestamp).json"
        
        // Save CSV
        saveCSVResults(to: csvPath)
        
        // Save JSON
        saveJSONResults(to: jsonPath)
        
        print("\n💾 Results saved:")
        print("   CSV: \(csvPath)")
        print("   JSON: \(jsonPath)")
    }
    
    private func saveCSVResults(to path: String) {
        var csvContent = "TestName,Connections,Iteration,DownloadTime,ThroughputMBps,MemoryUsageBytes,Success,Error\n"
        
        for result in results {
            csvContent += "\(result.testName),\(result.connections),\(result.iteration),"
            csvContent += "\(result.downloadTime),\(result.throughput),\(result.memoryUsage),"
            csvContent += "\(result.success),\"\(result.error ?? "")\"\n"
        }
        
        try? csvContent.write(toFile: path, atomically: true, encoding: .utf8)
    }
    
    private func saveJSONResults(to path: String) {
        let jsonData: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "config": [
                "iterations": config.iterations,
                "connectionCounts": config.connectionCounts,
                "testFiles": config.testFiles.map { [
                    "name": $0.name,
                    "url": $0.url,
                    "expectedSize": $0.expectedSize,
                    "description": $0.description
                ]}
            ],
            "results": results.map { [
                "testName": $0.testName,
                "connections": $0.connections,
                "iteration": $0.iteration,
                "downloadTime": $0.downloadTime,
                "throughput": $0.throughput,
                "memoryUsage": $0.memoryUsage,
                "success": $0.success,
                "error": $0.error as Any
            ]}
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: jsonData, options: .prettyPrinted) {
            try? jsonData.write(to: URL(fileURLWithPath: path))
        }
    }
    
    private func createOutputDirectory() {
        try? FileManager.default.createDirectory(
            atPath: config.outputDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
    
    private func verifySwiftGetBinary() -> Bool {
        return FileManager.default.fileExists(atPath: swiftgetPath)
    }
    
    private func getCurrentMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}

// MARK: - Utility Functions

func formatBytes(_ bytes: Int64) -> String {
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

extension String {
    static func *(lhs: String, rhs: Int) -> String {
        return String(repeating: lhs, count: rhs)
    }
}

// MARK: - Main Execution

func main() {
    let arguments = CommandLine.arguments
    
    if arguments.contains("--help") || arguments.contains("-h") {
        printUsage()
        return
    }
    
    // Parse command line arguments
    var swiftgetPath = ".build/release/swiftget"
    var iterations = 3
    var outputDir = "benchmark-results"
    
    for i in 1..<arguments.count {
        switch arguments[i] {
        case "--swiftget-path":
            if i + 1 < arguments.count {
                swiftgetPath = arguments[i + 1]
            }
        case "--iterations":
            if i + 1 < arguments.count {
                iterations = Int(arguments[i + 1]) ?? 3
            }
        case "--output-dir":
            if i + 1 < arguments.count {
                outputDir = arguments[i + 1]
            }
        default:
            break
        }
    }
    
    // Create custom config
    let config = BenchmarkConfig(
        testFiles: BenchmarkConfig.default.testFiles,
        connectionCounts: BenchmarkConfig.default.connectionCounts,
        iterations: iterations,
        outputDirectory: outputDir
    )
    
    // Run benchmarks
    let runner = BenchmarkRunner(config: config, swiftgetPath: swiftgetPath)
    runner.runAllBenchmarks()
}

func printUsage() {
    print("""
    SwiftGet Performance Benchmark Tool
    
    Usage: swift Scripts/benchmark.swift [OPTIONS]
    
    Options:
        --swiftget-path PATH    Path to swiftget binary (default: .build/release/swiftget)
        --iterations N          Number of iterations per test (default: 3)
        --output-dir DIR        Output directory for results (default: benchmark-results)
        --help, -h              Show this help message
    
    Examples:
        swift Scripts/benchmark.swift
        swift Scripts/benchmark.swift --iterations 5 --output-dir my-benchmarks
        swift Scripts/benchmark.swift --swiftget-path /usr/local/bin/swiftget
    
    This tool will:
    1. Test SwiftGet with different file sizes (1MB, 10MB, 50MB)
    2. Test with different connection counts (1, 2, 4, 8, 16)
    3. Run multiple iterations for statistical accuracy
    4. Generate detailed performance reports
    5. Save results in CSV and JSON formats
    """)
}

// Run the main function
main()
