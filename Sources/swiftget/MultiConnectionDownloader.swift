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

    func complete() {
        progressReporter.complete()
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
            logger.info("Falling back to single-connection download for \(url.lastPathComponent)")
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

        // Parallel download
        try await withThrowingTaskGroup(of: Void.self) { group in
            for segment in segmentRanges {
                group.addTask {
                    try await self.downloadSegment(segment: segment, to: tmpDir, outputFilename: outputURL.lastPathComponent, aggregator: aggregator)
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

        aggregator.complete()

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
            NSWorkspace.shared.selectFile(outputURL.path, inFileViewerRootedAtPath: tmpDir.path)
        }
        #endif
    }

    // MARK: - Helpers

    private func fetchContentInfo() async throws -> (Int64?, Bool) {
        var request = URLRequest(url: url)
        setupRequest(&request)
        request.httpMethod = "HEAD"
        let (data, response) = try await session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else { return (nil, false) }
        let lengthString = httpResp.value(forHTTPHeaderField: "Content-Length")
        let acceptRanges = httpResp.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false
        let contentLength = lengthString.flatMap { Int64($0) }
        return (contentLength, acceptRanges)
    }

    private static func splitSegments(contentLength: Int64, numSegments: Int) -> [SegmentRange] {
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

    private func downloadSegment(segment: SegmentRange, to tmpDir: URL, outputFilename: String, aggregator: ConcurrentProgressAggregator) async throws {
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
        try fileHandle.seek(toOffset: 0)

        defer { try? fileHandle.close() }

        // Streaming download
        let (inputStream, response) = try await session.bytes(for: request)
        guard let httpResp = response as? HTTPURLResponse, (httpResp.statusCode == 206 || httpResp.statusCode == 200) else {
            throw DownloadError.networkError(NSError(domain: "Segment status not 200/206", code: 0))
        }

        var bytesThisSegment: Int64 = 0
        let bufferSize = 128 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let count = try inputStream.read(into: buffer, maxLength: bufferSize)
            if count == 0 { break }
            let data = Data(bytes: buffer, count: count)
            try fileHandle.write(contentsOf: data)
            bytesThisSegment += Int64(count)
            await aggregator.report(segmentBytes: Int64(count))
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

    // MARK: - Post-processing (copied from SimpleFileDownloader)

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