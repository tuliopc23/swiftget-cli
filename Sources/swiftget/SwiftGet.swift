import ArgumentParser
import Foundation
import Logging

@main
struct SwiftGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftget",
        abstract: "A fast, modern download manager for macOS",
        version: "2.0.0",
        subcommands: [Download.self, Config.self],
        defaultSubcommand: Download.self
    )
}

extension SwiftGet {
    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download files from URLs"
        )
        
        @Argument(help: "URLs to download")
        var urls: [String] = []
        
        @Option(name: .shortAndLong, help: "Output directory")
        var directory: String?
        
        @Option(name: .shortAndLong, help: "Output filename")
        var output: String?
        
        @Option(name: .shortAndLong, help: "Number of connections per download")
        var connections: Int = 1
        
        @Option(name: .shortAndLong, help: "Maximum download speed (bytes/sec)")
        var maxSpeed: Int?
        
        @Option(name: .long, help: "User agent string")
        var userAgent: String?
        
        @Option(name: .long, help: "HTTP headers (format: 'Header: Value')")
        var header: [String] = []
        
        @Option(name: .long, help: "Proxy URL")
        var proxy: String?
        
        @Option(name: .long, help: "Input file containing URLs")
        var inputFile: String?
        
        @Option(name: .long, help: "Expected checksum (format: 'algorithm:hash')")
        var checksum: String?
        
        @Flag(name: .long, help: "Continue partial downloads")
        var `continue`: Bool = false
        
        @Flag(name: .shortAndLong, help: "Quiet mode")
        var quiet: Bool = false
        
        @Flag(name: .shortAndLong, help: "Verbose output")
        var verbose: Bool = false
        
        @Flag(name: .long, inversion: .prefixedNo, help: "Show progress bar")
        var progress: Bool = true
        
        @Flag(name: .long, inversion: .prefixedNo, help: "Verify SSL certificates")
        var checkCertificate: Bool = true
        
        @Flag(name: .long, help: "Auto-extract archives")
        var extract: Bool = false
        
        @Flag(name: .long, help: "Open downloaded file in Finder")
        var openInFinder: Bool = false
        
        func run() async throws {
            let config = DownloadConfiguration(
                directory: directory,
                output: output,
                connections: connections,
                maxSpeed: maxSpeed,
                userAgent: userAgent,
                headers: parseHeaders(header),
                proxy: proxy,
                checksum: parseChecksum(checksum),
                continueDownload: `continue`,
                quiet: quiet,
                verbose: verbose,
                showProgress: progress && !quiet,
                checkCertificate: checkCertificate,
                extract: extract,
                openInFinder: openInFinder
            )
            
            let downloadManager = DownloadManager(configuration: config)
            
            var urlsToDownload = urls
            
            // Load URLs from input file if specified
            if let inputFile = inputFile {
                let fileUrls = try await loadUrlsFromFile(inputFile)
                urlsToDownload.append(contentsOf: fileUrls)
            }
            
            guard !urlsToDownload.isEmpty else {
                throw ValidationError("No URLs provided. Use --help for usage information.")
            }
            
            try await downloadManager.downloadUrls(urlsToDownload)
        }
        
        private func parseHeaders(_ headers: [String]) -> [String: String] {
            var result: [String: String] = [:]
            for header in headers {
                let parts = header.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    result[key] = value
                }
            }
            return result
        }
        
        private func parseChecksum(_ checksum: String?) -> ChecksumInfo? {
            guard let checksum = checksum else { return nil }
            let parts = checksum.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            
            let algorithm = String(parts[0]).lowercased()
            let hash = String(parts[1])
            
            switch algorithm {
            case "md5":
                return ChecksumInfo(algorithm: .md5, hash: hash)
            case "sha1":
                return ChecksumInfo(algorithm: .sha1, hash: hash)
            case "sha256":
                return ChecksumInfo(algorithm: .sha256, hash: hash)
            default:
                return nil
            }
        }
        
        private func loadUrlsFromFile(_ filePath: String) async throws -> [String] {
            let fileURL = URL(fileURLWithPath: filePath)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            return content.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
    }
    
    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage configuration settings"
        )
        
        @Flag(help: "Show current configuration")
        var show: Bool = false
        
        @Option(help: "Set configuration value (format: 'key=value')")
        var set: String?
        
        func run() throws {
            let configManager = ConfigurationManager()
            
            if show {
                configManager.showConfiguration()
            } else if let setValue = set {
                try configManager.setConfiguration(setValue)
            } else {
                print("Use --show to display configuration or --set key=value to set a value")
            }
        }
    }
}