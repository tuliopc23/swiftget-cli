import Foundation
#if os(Linux)
import Glibc
#endif

/// Enhanced progress reporting mode for different display styles
enum ProgressDisplayMode {
    case simple           // Single line progress bar
    case detailed         // Multi-line with speed, ETA, segments
    case compact          // Compact single line with key metrics
    case segments         // Show individual segment progress
}

/// Progress display configuration
struct ProgressDisplayConfig {
    let mode: ProgressDisplayMode
    let showSegments: Bool
    let updateInterval: TimeInterval
    let progressBarWidth: Int
    
    static let `default` = ProgressDisplayConfig(
        mode: .simple,
        showSegments: false,
        updateInterval: 0.1,
        progressBarWidth: 30
    )
    
    static let multiConnection = ProgressDisplayConfig(
        mode: .detailed,
        showSegments: true,
        updateInterval: 0.1,
        progressBarWidth: 40
    )
}

class ProgressReporter {
    private let startTime: Date
    private let url: URL
    private let quiet: Bool
    private let config: ProgressDisplayConfig
    private let totalBytes: Int64?

    // Internal state for throttling updates and speed calculation
    private var lastUpdateTime: Date
    private var lastBytesDownloaded: Int64
    private var speedHistory: [Double] = []
    private let speedHistorySize = 10
    
    // Multi-segment tracking
    private var segmentCount: Int = 1
    private var displayLines: Int = 0

    // When totalBytes is known up-front (e.g., multi-connection), pass it for smoother initial display
    init(url: URL, quiet: Bool, totalBytes: Int64? = nil, config: ProgressDisplayConfig = .default) {
        self.startTime = Date()
        self.url = url
        self.quiet = quiet
        self.config = config
        self.totalBytes = totalBytes
        self.lastUpdateTime = self.startTime
        self.lastBytesDownloaded = 0

        if !quiet {
            displayInitialMessage()
        }
    }

    /// Update progress display with optional speed parameter, throttled to configured interval
    func updateProgress(bytesDownloaded: Int64, totalBytes: Int64?, speed: Double? = nil) {
        guard !quiet else { return }

        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)

        // Update progress at configured interval to avoid spam
        guard timeSinceLastUpdate >= config.updateInterval else { return }

        let calculatedSpeed: Double
        if let providedSpeed = speed {
            calculatedSpeed = providedSpeed
        } else {
            let bytesSinceLastUpdate = bytesDownloaded - lastBytesDownloaded
            calculatedSpeed = timeSinceLastUpdate > 0 ? Double(bytesSinceLastUpdate) / timeSinceLastUpdate : 0
        }
        
        updateSpeedHistory(calculatedSpeed)
        
        let finalTotalBytes = totalBytes ?? self.totalBytes
        displayProgress(
            bytesDownloaded: bytesDownloaded,
            totalBytes: finalTotalBytes,
            speed: calculatedSpeed,
            elapsedTime: now.timeIntervalSince(startTime)
        )

        lastUpdateTime = now
        lastBytesDownloaded = bytesDownloaded
    }

    /// Call when download is complete to show final message.
    func complete() {
        guard !quiet else { return }
        
        // Clear any multi-line display
        if displayLines > 0 {
            clearDisplayLines()
        }
        
        let totalTime = Date().timeIntervalSince(startTime)
        let averageSpeed = getAverageSpeed()
        
        if segmentCount > 1 {
            let speedStr = formatBytes(Int64(averageSpeed)) + "/s"
            print("\nDownload completed in \(formatTime(totalTime)) using \(segmentCount) connections (avg: \(speedStr))")
        } else {
            print("\nDownload completed in \(formatTime(totalTime))")
        }
    }

    /// Update progress with segment information for multi-connection downloads
    func updateSegmentProgress(_ segments: [SegmentProgress]) {
        guard !quiet, config.showSegments else { return }
        
        segmentCount = segments.count
        let totalDownloaded = segments.reduce(0) { $0 + $1.bytesDownloaded }
        let totalBytes = segments.reduce(0) { $0 + $1.totalBytes }
        let averageSpeed = segments.reduce(0.0) { $0 + $1.averageSpeed }
        
        clearDisplayLines()
        
        // Display overall progress
        let elapsedTime = Date().timeIntervalSince(startTime)
        let progressString = formatProgress(
            bytesDownloaded: totalDownloaded,
            totalBytes: totalBytes,
            speed: averageSpeed,
            elapsedTime: elapsedTime,
            isMultiSegment: true
        )
        
        print(progressString)
        displayLines = 1
        
        // Display individual segment progress in detailed mode
        if config.mode == .detailed || config.mode == .segments {
            for segment in segments.sorted(by: { $0.segmentIndex < $1.segmentIndex }) {
                let segmentProgressString = formatSegmentProgress(segment)
                print(segmentProgressString)
                displayLines += 1
            }
        }
        
        // Move cursor back up to overwrite next time
        if displayLines > 1 {
            print("\u{1B}[\(displayLines - 1)A", terminator: "")
        }
        
        Task.detached { @MainActor in
            fflush(stdout)
        }
    }

    // MARK: - Private Methods
    
    private func displayInitialMessage() {
        if let totalBytes = totalBytes {
            let totalStr = formatBytes(totalBytes)
            print("Downloading: \(url.lastPathComponent) (\(totalStr))")
        } else {
            print("Downloading: \(url.lastPathComponent)")
        }
    }
    
    private func updateSpeedHistory(_ speed: Double) {
        speedHistory.append(speed)
        if speedHistory.count > speedHistorySize {
            speedHistory.removeFirst()
        }
    }
    
    private func getAverageSpeed() -> Double {
        guard !speedHistory.isEmpty else { return 0.0 }
        return speedHistory.reduce(0, +) / Double(speedHistory.count)
    }
    
    private func displayProgress(bytesDownloaded: Int64, totalBytes: Int64?, speed: Double, elapsedTime: TimeInterval) {
        let progressString: String
        
        switch config.mode {
        case .simple:
            progressString = formatProgress(
                bytesDownloaded: bytesDownloaded,
                totalBytes: totalBytes,
                speed: speed,
                elapsedTime: elapsedTime
            )
        case .compact:
            progressString = formatCompactProgress(
                bytesDownloaded: bytesDownloaded,
                totalBytes: totalBytes,
                speed: speed
            )
        case .detailed, .segments:
            progressString = formatDetailedProgress(
                bytesDownloaded: bytesDownloaded,
                totalBytes: totalBytes,
                speed: speed,
                elapsedTime: elapsedTime
            )
        }
        
        // Clear the line and print new progress
        print("\r\u{1B}[K\(progressString)", terminator: "")
        Task.detached { @MainActor in
            fflush(stdout)
        }
    }
    
    private func clearDisplayLines() {
        if displayLines > 0 {
            for _ in 0..<displayLines {
                print("\r\u{1B}[K\u{1B}[1A", terminator: "")
            }
            print("\r\u{1B}[K", terminator: "")
            displayLines = 0
        }
    }

    // MARK: - Formatting helpers

    private func formatProgress(bytesDownloaded: Int64, totalBytes: Int64?, speed: Double, elapsedTime: TimeInterval, isMultiSegment: Bool = false) -> String {
        let downloadedStr = formatBytes(bytesDownloaded)
        let speedStr = formatBytes(Int64(getAverageSpeed())) + "/s"
        let elapsedStr = formatTime(elapsedTime)

        if let totalBytes = totalBytes, totalBytes > 0 {
            let percentage = Double(bytesDownloaded) / Double(totalBytes) * 100
            let totalStr = formatBytes(totalBytes)
            let eta = speed > 0 ? formatTime(Double(totalBytes - bytesDownloaded) / speed) : "∞"

            let progressBar = createProgressBar(percentage: percentage, width: config.progressBarWidth)
            let segmentInfo = isMultiSegment ? " (\(segmentCount) segments)" : ""

            return String(format: "%@ %@ / %@ (%.1f%%) %@ ETA: %@ [%@]%@",
                          progressBar, downloadedStr, totalStr, percentage, speedStr, eta, elapsedStr, segmentInfo)
        } else {
            return String(format: "%@ %@ [%@]", downloadedStr, speedStr, elapsedStr)
        }
    }
    
    private func formatCompactProgress(bytesDownloaded: Int64, totalBytes: Int64?, speed: Double) -> String {
        let downloadedStr = formatBytes(bytesDownloaded)
        let speedStr = formatBytes(Int64(speed)) + "/s"
        
        if let totalBytes = totalBytes, totalBytes > 0 {
            let percentage = Double(bytesDownloaded) / Double(totalBytes) * 100
            return String(format: "%.1f%% %@ (%@)", percentage, downloadedStr, speedStr)
        } else {
            return String(format: "%@ (%@)", downloadedStr, speedStr)
        }
    }
    
    private func formatDetailedProgress(bytesDownloaded: Int64, totalBytes: Int64?, speed: Double, elapsedTime: TimeInterval) -> String {
        let downloadedStr = formatBytes(bytesDownloaded)
        let speedStr = formatBytes(Int64(getAverageSpeed())) + "/s"
        let instantSpeedStr = formatBytes(Int64(speed)) + "/s"
        let elapsedStr = formatTime(elapsedTime)
        
        if let totalBytes = totalBytes, totalBytes > 0 {
            let percentage = Double(bytesDownloaded) / Double(totalBytes) * 100
            let totalStr = formatBytes(totalBytes)
            let eta = speed > 0 ? formatTime(Double(totalBytes - bytesDownloaded) / speed) : "∞"
            let progressBar = createProgressBar(percentage: percentage, width: config.progressBarWidth)
            
            return String(format: "%@ %@ / %@ (%.1f%%) avg: %@ curr: %@ ETA: %@ [%@]",
                          progressBar, downloadedStr, totalStr, percentage, speedStr, instantSpeedStr, eta, elapsedStr)
        } else {
            return String(format: "%@ avg: %@ curr: %@ [%@]", downloadedStr, speedStr, instantSpeedStr, elapsedStr)
        }
    }
    
    private func formatSegmentProgress(_ segment: SegmentProgress) -> String {
        let percentage = segment.progressPercentage * 100
        let downloadedStr = formatBytes(segment.bytesDownloaded)
        let totalStr = formatBytes(segment.totalBytes)
        let speedStr = formatBytes(Int64(segment.averageSpeed)) + "/s"
        let progressBar = createProgressBar(percentage: percentage, width: 20)
        let status = segment.isComplete ? "✓" : "↓"
        
        return String(format: "  %@ Segment %d: %@ %@ / %@ (%.1f%%) %@",
                      status, segment.segmentIndex, progressBar, downloadedStr, totalStr, percentage, speedStr)
    }

    private func createProgressBar(percentage: Double, width: Int? = nil) -> String {
        let barWidth = width ?? config.progressBarWidth
        let filled = Int(percentage / 100.0 * Double(barWidth))
        let empty = barWidth - filled

        let filledBar = String(repeating: "█", count: max(0, filled))
        let emptyBar = String(repeating: "░", count: max(0, empty))

        return "[\(filledBar)\(emptyBar)]"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
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

    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}