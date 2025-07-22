import Foundation
import Logging
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import AppKit
#endif

class SimpleFileDownloader {
    private let url: URL
    private let configuration: DownloadConfiguration
    private let session: URLSession
    private let logger: Logger
    
    private var progressReporter: ProgressReporter?
    
    init(url: URL, configuration: DownloadConfiguration, session: URLSession, logger: Logger) {
        self.url = url
        self.configuration = configuration
        self.session = session
        self.logger = logger
    }
    
    func download() async throws {
        let outputURL = try determineOutputURL()
        
        // Check if file exists and handle resume
        if configuration.continueDownload && FileManager.default.fileExists(atPath: outputURL.path) {
            try await resumeDownload(to: outputURL)
        } else {
            try await startNewDownload(to: outputURL)
        }
    }
    
    private func startNewDownload(to outputURL: URL) async throws {
        var request = URLRequest(url: url)
        setupRequest(&request)
        
        logger.debug("Starting new download to: \(outputURL.path)")
        
        if configuration.showProgress {
            progressReporter = ProgressReporter(url: url, quiet: configuration.quiet)
        }
        
        let (data, response) = try await session.data(for: request)
        
        try await processDownloadedData(data, to: outputURL, response: response)
    }
    
    private func resumeDownload(to outputURL: URL) async throws {
        // For simplicity, we'll implement basic resume by checking file size
        let existingSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
        
        var request = URLRequest(url: url)
        setupRequest(&request)
        
        // Add Range header for resume
        if existingSize > 0 {
            request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
            logger.debug("Resuming download from byte \(existingSize)")
        }
        
        if configuration.showProgress {
            progressReporter = ProgressReporter(url: url, quiet: configuration.quiet)
            progressReporter?.updateProgress(bytesDownloaded: existingSize, totalBytes: nil)
        }
        
        let (data, response) = try await session.data(for: request)
        
        // If we got a partial content response, append to existing file
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 206 {
            try await appendDownloadedData(data, to: outputURL, response: response)
        } else {
            // Server doesn't support resume, start over
            try await processDownloadedData(data, to: outputURL, response: response)
        }
    }
    
    private func setupRequest(_ request: inout URLRequest) {
        request.setValue(configuration.effectiveUserAgent, forHTTPHeaderField: "User-Agent")
        
        for (key, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        if !configuration.checkCertificate {
            logger.warning("SSL certificate verification disabled")
        }
    }
    
    private func processDownloadedData(_ data: Data, to outputURL: URL, response: URLResponse) async throws {
        // Create output directory if needed
        let outputDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        // Write data to file
        try data.write(to: outputURL)
        
        logger.info("Downloaded: \(outputURL.path)")
        
        // Update progress to show completion
        progressReporter?.updateProgress(bytesDownloaded: Int64(data.count), totalBytes: Int64(data.count))
        
        // Verify checksum if provided
        if let checksumInfo = configuration.checksum {
            try await verifyChecksum(file: outputURL, checksumInfo: checksumInfo)
        }
        
        // Extract if requested
        if configuration.extract {
            try await extractFile(outputURL)
        }
        
        // Open in Finder if requested (macOS only)
        #if os(macOS)
        if configuration.openInFinder {
            NSWorkspace.shared.selectFile(outputURL.path, inFileViewerRootedAtPath: outputDir.path)
        }
        #endif
        
        progressReporter?.complete()
    }
    
    private func appendDownloadedData(_ data: Data, to outputURL: URL, response: URLResponse) async throws {
        let fileHandle = try FileHandle(forWritingTo: outputURL)
        defer { fileHandle.closeFile() }
        
        fileHandle.seekToEndOfFile()
        fileHandle.write(data)
        
        logger.info("Resumed download completed: \(outputURL.path)")
        
        // Get total file size for progress
        let totalSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
        progressReporter?.updateProgress(bytesDownloaded: totalSize, totalBytes: totalSize)
        
        // Verify checksum if provided
        if let checksumInfo = configuration.checksum {
            try await verifyChecksum(file: outputURL, checksumInfo: checksumInfo)
        }
        
        progressReporter?.complete()
    }
    
    private func determineOutputURL() throws -> URL {
        let baseURL = configuration.effectiveDirectory
        
        if let output = configuration.output {
            return baseURL.appendingPathComponent(output)
        } else {
            let filename = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
            return baseURL.appendingPathComponent(filename)
        }
    }
    
    private func verifyChecksum(file: URL, checksumInfo: ChecksumInfo) async throws {
        let data = try Data(contentsOf: file)
        let actualHash: String
        
        switch checksumInfo.algorithm {
        case .md5:
            actualHash = Insecure.MD5.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        case .sha1:
            actualHash = Insecure.SHA1.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        case .sha256:
            actualHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        }
        
        if actualHash.lowercased() != checksumInfo.hash.lowercased() {
            throw DownloadError.checksumMismatch(expected: checksumInfo.hash, actual: actualHash)
        }
        
        logger.info("Checksum verified: \(checksumInfo.algorithm) = \(actualHash)")
    }
    
    private func extractFile(_ fileURL: URL) async throws {
        let fileExtension = fileURL.pathExtension.lowercased()
        
        switch fileExtension {
        case "zip":
            try await extractZipFile(fileURL)
        case "tar", "gz", "tgz":
            logger.warning("Archive extraction for \(fileExtension) not yet implemented")
        default:
            logger.debug("File \(fileURL.lastPathComponent) is not a recognized archive format")
        }
    }
    
    private func extractZipFile(_ zipURL: URL) async throws {
        let extractDir = zipURL.deletingPathExtension()
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        
        // Use system unzip command for simplicity
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", extractDir.path]
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            logger.info("Extracted archive to: \(extractDir.path)")
        } else {
            logger.error("Failed to extract archive: \(zipURL.path)")
        }
    }
}