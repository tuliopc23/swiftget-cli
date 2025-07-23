import Foundation
import Logging
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

        // Streaming download to avoid memory blow-up
        let (inputStream, response) = try await session.bytes(for: request)

        // Create output directory if needed
        let outputDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Overwrite if already exists
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: outputURL.path) else {
            throw DownloadError.fileSystemError(NSError(domain: "Cannot open output file", code: 0))
        }
        defer { try? fileHandle.close() }

        let limiter: SpeedLimiter? = configuration.maxSpeed != nil ? SpeedLimiter(maxBytesPerSecond: configuration.maxSpeed!) : nil

        var totalBytes: Int64 = 0
        let bufferSize = 128 * 1024

        for try await chunk in inputStream {
            try fileHandle.write(contentsOf: chunk)
            totalBytes += Int64(chunk.count)
            if let limiter = limiter {
                await limiter.throttle(wrote: chunk.count)
            }
            progressReporter?.updateProgress(bytesDownloaded: totalBytes, totalBytes: nil)
        }

        logger.info("Downloaded: \(outputURL.path)")

        progressReporter?.updateProgress(bytesDownloaded: totalBytes, totalBytes: totalBytes)
        progressReporter?.complete()

        // Verify checksum if provided
        if let checksumInfo = configuration.checksum {
            try ChecksumVerifier.verify(file: outputURL, against: checksumInfo, logger: logger)
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
    }

    private func resumeDownload(to outputURL: URL) async throws {
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

        let (inputStream, response) = try await session.bytes(for: request)

        // Open file for appending
        guard let fileHandle = FileHandle(forWritingAtPath: outputURL.path) else {
            throw DownloadError.fileSystemError(NSError(domain: "Cannot open output file", code: 0))
        }
        try fileHandle.seekToEnd()

        let limiter: SpeedLimiter? = configuration.maxSpeed != nil ? SpeedLimiter(maxBytesPerSecond: configuration.maxSpeed!) : nil

        var totalBytes = existingSize

        for try await chunk in inputStream {
            try fileHandle.write(contentsOf: chunk)
            totalBytes += Int64(chunk.count)
            if let limiter = limiter {
                await limiter.throttle(wrote: chunk.count)
            }
            progressReporter?.updateProgress(bytesDownloaded: totalBytes, totalBytes: nil)
        }

        logger.info("Resumed download completed: \(outputURL.path)")

        progressReporter?.updateProgress(bytesDownloaded: totalBytes, totalBytes: totalBytes)
        progressReporter?.complete()

        // Verify checksum if provided
        if let checksumInfo = configuration.checksum {
            try ChecksumVerifier.verify(file: outputURL, against: checksumInfo, logger: logger)
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

    private func determineOutputURL() throws -> URL {
        let baseURL = configuration.effectiveDirectory

        if let output = configuration.output {
            return baseURL.appendingPathComponent(output)
        } else {
            let filename = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
            return baseURL.appendingPathComponent(filename)
        }
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