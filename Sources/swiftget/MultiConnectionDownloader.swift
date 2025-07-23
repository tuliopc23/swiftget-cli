import Foundation
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import AppKit
#endif

// Aggregates progress from all segments and forwards to ProgressReporter
actor ConcurrentProgressAggregator {
    private var totalBytesDownloaded: Int64 = 0
    private let totalBytes: Int64
    private let progressReporter: ProgressReporter

    init(totalBytes: Int64, progressReporter: ProgressReporter) {
        self.totalBytes = totalBytes
        self.progressReporter = progressReporter
    }

    func report(segmentBytes: Int64) {
        totalBytesDownloaded += segmentBytes
        progressReporter.updateProgress(bytesDownloaded: totalBytesDownloaded, totalBytes: totalBytes)
    }

    nonisolated func complete() async {
        await progressReporter.complete()
    }
}

struct SegmentRange {
    let index: Int
    let start: Int64
    let end: Int64 // inclusive
}

class MultiConnectionDownloader {
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
        let (contentLength, acceptRanges) = try await fetchContentInfo()
        guard let contentLength = contentLength, acceptRanges == true, configuration.connections > 1 else {
            logger.warning("Falling back to single-connection download for \(url.lastPathComponent)")
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

        let segmentRanges = MultiConnectionDownloader.splitSegments(contentLength: contentLength, numSegments: configuration.connections)
        let progressReporter = ProgressReporter(url: url, quiet: configuration.quiet, totalBytes: contentLength)
        let aggregator = ConcurrentProgressAggregator(totalBytes: contentLength, progressReporter: progressReporter)

        let tmpDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Remove any old part files if present
        for seg in segmentRanges {
            let partURL = tmpDir.appendingPathComponent("\(outputURL.lastPathComponent).part\(seg.index)")
            try? FileManager.default.removeItem(at: partURL)
        }

        let limiter: SpeedLimiter? = configuration.maxSpeed != nil ? SpeedLimiter(maxBytesPerSecond: configuration.maxSpeed!) : nil
        let maxAttempts = 3

        // Parallel download with retry logic
        try await withThrowingTaskGroup(of: Void.self) { group in
            for segment in segmentRanges {
                group.addTask {
                    try await self.downloadSegment(segment: segment,
                                                   to: tmpDir,
                                                   outputFilename: outputURL.lastPathComponent,
                                                   aggregator: aggregator,
                                                   limiter: limiter,
                                                   attempts: maxAttempts)
                }
            }
            try await group.waitForAll()
        }

        // Concatenate part files
        try assembleParts(segmentRanges: segmentRanges, tmpDir: tmpDir, outputURL: outputURL)

        // Clean up part files
        for seg in segmentRanges {
            let partURL = tmpDir.appendingPathComponent("\(outputURL.lastPathComponent).part\(seg.index)")
            try? FileManager.default.removeItem(at: partURL)
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

    static func splitSegments(contentLength: Int64, numSegments: Int) -> [SegmentRange] {
        let base = contentLength / Int64(numSegments)
        let rem = contentLength % Int64(numSegments)
        var segments: [SegmentRange] = []
        var start: Int64 = 0

        for i in 0..<numSegments {
            let extra = (i < rem) ? 1 : 0
            let segLen = base + Int64(extra)
            let end = start + segLen - 1
            segments.append(SegmentRange(index: i, start: start, end: end))
            start = end + 1
        }
        return segments
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

    private func downloadSegment(segment: SegmentRange, to tmpDir: URL, outputFilename: String, aggregator: ConcurrentProgressAggregator, limiter: SpeedLimiter?, attempts: Int) async throws {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                try await self.downloadSegmentOnce(segment: segment, to: tmpDir, outputFilename: outputFilename, aggregator: aggregator, limiter: limiter)
                return
            } catch {
                lastError = error
                logger.warning("Retrying segment \(segment.index) (\(attempt)/\(attempts)): \(error)")
                if attempt == attempts {
                    throw error
                }
            }
        }
        if let lastError = lastError {
            throw lastError
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

        // Streaming download
        let (inputStream, response) = try await session.bytes(for: request)
        guard let httpResp = response as? HTTPURLResponse, (httpResp.statusCode == 206 || httpResp.statusCode == 200) else {
            throw DownloadError.networkError(NSError(domain: "Segment status not 200/206", code: 0))
        }

        var bytesThisSegment: Int64 = 0

        for try await chunk in inputStream {
            if chunk.isEmpty { break }
            try fileHandle.write(contentsOf: chunk)
            bytesThisSegment += Int64(chunk.count)
            if let limiter = limiter {
                await limiter.throttle(wrote: chunk.count)
            }
            await aggregator.report(segmentBytes: Int64(chunk.count))
        }
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
        logger.info("Assembled file: \(outputURL.lastPathComponent)")
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