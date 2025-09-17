import Foundation
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import AppKit
#endif

class MultiConnectionDownloader: @unchecked Sendable {
    private let url: URL
    private let configuration: DownloadConfiguration
    private let session: URLSession
    private let logger: Logger

    init(url: URL, configuration: DownloadConfiguration, session: URLSession, logger: Logger) {
        self.url = url
        self.configuration = configuration
        self.session = session
        self.logger = logger
    }

    func download() async throws {
        let outputURL = try determineOutputURL()
        let segmentationStrategy = SegmentationStrategy(logger: logger)
        
        // Analyze server capabilities first
        let serverCapabilities = try await segmentationStrategy.analyzeServerCapabilities(
            url: url,
            session: session,
            headers: configuration.headers
        )
        
        // Get content length from capabilities or fallback to HEAD request
        let contentLength: Int64
        if let serverContentLength = serverCapabilities.contentLength {
            contentLength = serverContentLength
        } else {
            let (fallbackLength, _) = try await fetchContentInfo()
            guard let fallbackLength = fallbackLength else {
                throw DownloadError.connectionFailed(underlying: NSError(domain: "Cannot determine content length", code: -1))
            }
            contentLength = fallbackLength
        }
        
        guard contentLength > 0 else {
            logger.warning("Cannot determine content length for \(url.lastPathComponent)")
            // Fallback: Use SimpleFileDownloader
            let fallback = SimpleFileDownloader(
                url: url,
                configuration: configuration,
                session: session,
                logger: logger
            )
            try await fallback.download()
            return
        }
        
        // Calculate optimal segmentation using intelligent strategy
        let segmentRanges = segmentationStrategy.calculateOptimalSegmentation(
            contentLength: contentLength,
            requestedConnections: configuration.connections,
            serverCapabilities: serverCapabilities
        )
        
        // If only one segment recommended, fall back to simple downloader
        guard segmentRanges.count > 1 else {
            logger.info("Single segment recommended for \(url.lastPathComponent), using SimpleFileDownloader")
            let fallback = SimpleFileDownloader(
                url: url,
                configuration: configuration,
                session: session,
                logger: logger
            )
            try await fallback.download()
            return
        }

        let progressReporter = ProgressReporter(
            url: url, 
            quiet: configuration.quiet, 
            totalBytes: contentLength,
            config: .multiConnection
        )
        let aggregator = ConcurrentProgressAggregator(
            totalBytes: contentLength,
            progressReporter: progressReporter,
            segmentRanges: segmentRanges,
            logger: logger
        )

        let tmpDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Remove any old part files if present
        for seg in segmentRanges {
            let partURL = tmpDir.appendingPathComponent("\(outputURL.lastPathComponent).part\(seg.index)")
            try? FileManager.default.removeItem(at: partURL)
        }

        let limiter: SpeedLimiter? = configuration.maxSpeed != nil ? SpeedLimiter(maxBytesPerSecond: Int64(configuration.maxSpeed!)) : nil
        
        // Initialize error recovery
        let errorRecovery = SegmentErrorRecovery(logger: logger)
        await errorRecovery.initializeSegments(segmentRanges)
        
        // Track active segments for redistribution
        var activeSegmentRanges = segmentRanges

        // Enhanced parallel download with error recovery
        var downloadCompleted = false
        var fallbackToSingleConnection = false
        
        while !downloadCompleted && !fallbackToSingleConnection {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for segment in activeSegmentRanges {
                        group.addTask {
                            try await self.downloadSegmentWithRecovery(
                                segment: segment,
                                to: tmpDir,
                                outputFilename: outputURL.lastPathComponent,
                                aggregator: aggregator,
                                limiter: limiter,
                                errorRecovery: errorRecovery
                            )
                        }
                    }
                    try await group.waitForAll()
                }
                downloadCompleted = true
            } catch let segmentError as SegmentError {
                let strategy = await errorRecovery.handleSegmentFailure(segmentError)
                
                switch strategy {
                case .retry:
                    logger.info("Retrying failed segments")
                    // Continue the while loop to retry
                    
                case .redistribute:
                    logger.info("Redistributing segment \(segmentError.segmentIndex)")
                    let activeIndices = activeSegmentRanges.map { $0.index }
                    let newSegments = await errorRecovery.redistributeSegment(
                        segmentError.segmentIndex,
                        amongSegments: activeIndices
                    )
                    
                    // Remove failed segment and add redistributed segments
                    activeSegmentRanges.removeAll { $0.index == segmentError.segmentIndex }
                    activeSegmentRanges.append(contentsOf: newSegments)
                    
                case .fallback:
                    logger.warning("Falling back to single-connection download")
                    fallbackToSingleConnection = true
                    
                case .abort:
                    logger.error("Aborting download due to excessive failures")
                    let stats = await errorRecovery.getRecoveryStatistics()
                    throw DownloadError.connectionFailed(underlying: NSError(
                        domain: "Download aborted after \(stats.totalRetries) retries and \(stats.totalRedistributions) redistributions",
                        code: -1
                    ))
                }
            }
        }
        
        // Handle fallback to single connection if needed
        if fallbackToSingleConnection {
            logger.info("Switching to single-connection fallback")
            let fallback = SimpleFileDownloader(
                url: url,
                configuration: configuration,
                session: session,
                logger: logger
            )
            try await fallback.download()
            return
        }

        // Concatenate part files
        try assembleParts(segmentRanges: activeSegmentRanges, tmpDir: tmpDir, outputURL: outputURL)

        // Clean up part files
        for seg in activeSegmentRanges {
            let partURL = tmpDir.appendingPathComponent("\(outputURL.lastPathComponent).part\(seg.index)")
            try? FileManager.default.removeItem(at: partURL)
        }
        
        // Log recovery statistics
        let recoveryStats = await errorRecovery.getRecoveryStatistics()
        if recoveryStats.totalRetries > 0 || recoveryStats.totalRedistributions > 0 {
            logger.info("Download completed with \(recoveryStats.totalRetries) retries and \(recoveryStats.totalRedistributions) redistributions")
        }

        await aggregator.complete()

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
            NSWorkspace.shared.selectFile(outputURL.path, inFileViewerRootedAtPath: tmpDir.path)
        }
        #endif
    }

    // MARK: - Helpers

    private func fetchContentInfo() async throws -> (Int64?, Bool) {
        var request = URLRequest(url: url)
        setupRequest(&request)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else { return (nil, false) }
        let lengthString = httpResp.value(forHTTPHeaderField: "Content-Length")
        let acceptRanges = httpResp.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false
        let contentLength = lengthString.flatMap { Int64($0) }
        return (contentLength, acceptRanges)
    }

    // Legacy method kept for backward compatibility, but now delegates to SegmentationStrategy
    static func splitSegments(contentLength: Int64, numSegments: Int) -> [SegmentRange] {
        let strategy = SegmentationStrategy(logger: Logger(label: "legacy-segmentation"))
        let serverCapabilities = ServerCapabilities(acceptsRangeRequests: true, contentLength: contentLength)
        return strategy.calculateOptimalSegmentation(
            contentLength: contentLength,
            requestedConnections: numSegments,
            serverCapabilities: serverCapabilities
        )
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

    private func setupRequest(_ request: inout URLRequest) {
        request.setValue(configuration.effectiveUserAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !configuration.checkCertificate {
            logger.warning("SSL certificate verification disabled")
        }
    }

    private func downloadSegmentWithRecovery(
        segment: SegmentRange,
        to tmpDir: URL,
        outputFilename: String,
        aggregator: ConcurrentProgressAggregator,
        limiter: SpeedLimiter?,
        errorRecovery: SegmentErrorRecovery
    ) async throws {
        do {
            try await downloadSegmentOnce(
                segment: segment,
                to: tmpDir,
                outputFilename: outputFilename,
                aggregator: aggregator,
                limiter: limiter
            )
            
            // Mark segment as complete in aggregator
            await aggregator.markSegmentComplete(segmentIndex: segment.index)
            
        } catch {
            // Classify the error and create SegmentError
            let segmentError = await errorRecovery.classifyError(
                error,
                segmentIndex: segment.index,
                attemptNumber: 1,
                bytesTransferred: 0 // TODO: Track actual bytes transferred
            )
            
            // Re-throw as SegmentError for handling by the recovery system
            throw segmentError
        }
    }

    private func downloadSegmentOnce(segment: SegmentRange, to tmpDir: URL, outputFilename: String, aggregator: ConcurrentProgressAggregator, limiter: SpeedLimiter?) async throws {
        let partURL = tmpDir.appendingPathComponent("\(outputFilename).part\(segment.index)")
        var request = URLRequest(url: url)
        setupRequest(&request)
        request.setValue("bytes=\(segment.start)-\(segment.end)", forHTTPHeaderField: "Range")

        // Ensure .part file exists
        if !FileManager.default.fileExists(atPath: partURL.path) {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }

        guard let fileHandle = FileHandle(forWritingAtPath: partURL.path) else {
            throw DownloadError.fileSystemError(NSError(domain: "Cannot open part file for writing", code: 0))
        }

        // Atomic overwrite: truncate and seek to 0 before writing
        try fileHandle.truncate(atOffset: 0)
#if compiler(>=5.3)
        try fileHandle.seek(toOffset: 0)
#else
        fileHandle.seek(toFileOffset: 0)
#endif

        defer { try? fileHandle.close() }

        // Use traditional data method for cross-platform compatibility
        let (data, response) = try await session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, (httpResp.statusCode == 206 || httpResp.statusCode == 200) else {
            throw DownloadError.connectionFailed(underlying: NSError(domain: "Segment status not 200/206", code: 0))
        }

        let bytesThisSegment = Int64(data.count)

        // Write all data at once
        guard !data.isEmpty else { return }
        try fileHandle.write(contentsOf: data)
        if let limiter = limiter {
            await limiter.throttle(wrote: data.count)
        }
        await aggregator.reportSegmentProgress(segmentIndex: segment.index, additionalBytes: bytesThisSegment)
    }

    private func assembleParts(segmentRanges: [SegmentRange], tmpDir: URL, outputURL: URL) throws {
        // Remove final output if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let outHandle = FileHandle(forWritingAtPath: outputURL.path) else {
            throw DownloadError.fileSystemError(NSError(domain: "Cannot open output file", code: 0))
        }
        defer { try? outHandle.close() }

        for seg in segmentRanges {
            let partURL = tmpDir.appendingPathComponent("\(outputURL.lastPathComponent).part\(seg.index)")
            guard let inHandle = FileHandle(forReadingAtPath: partURL.path) else {
                throw DownloadError.fileSystemError(NSError(domain: "Cannot open part file", code: 0))
            }
            defer { try? inHandle.close() }
            while true {
                let chunk = try inHandle.read(upToCount: 128 * 1024)
                if let chunk = chunk, !chunk.isEmpty {
                    try outHandle.write(contentsOf: chunk)
                } else {
                    break
                }
            }
        }
        logger.info("Assembled file: \(outputURL.lastPathComponent) from \(segmentRanges.count) segments")
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