import Foundation
#if os(Linux)
import Glibc
#endif

class ProgressReporter {
    private let startTime: Date
    private let url: URL
    private let quiet: Bool

    // Internal state for throttling updates and speed calculation
    private var lastUpdateTime: Date
    private var lastBytesDownloaded: Int64

    // When totalBytes is known up-front (e.g., multi-connection), pass it for smoother initial display
    init(url: URL, quiet: Bool, totalBytes: Int64? = nil) {
        self.startTime = Date()
        self.url = url
        self.quiet = quiet
        self.lastUpdateTime = self.startTime
        self.lastBytesDownloaded = 0

        if !quiet {
            if let totalBytes = totalBytes {
                let totalStr = formatBytes(totalBytes)
                print("Downloading: \(url.lastPathComponent) (\(totalStr))")
            } else {
                print("Downloading: \(url.lastPathComponent)")
            }
        }
    }

    /// Update progress display, throttled to once per 0.1s.
    func updateProgress(bytesDownloaded: Int64, totalBytes: Int64?) {
        guard !quiet else { return }

        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)

        // Update progress at most once per 0.1 seconds to avoid spam
        guard timeSinceLastUpdate >= 0.1 else { return }

        let bytesSinceLastUpdate = bytesDownloaded - lastBytesDownloaded
        let speed = timeSinceLastUpdate > 0 ? Double(bytesSinceLastUpdate) / timeSinceLastUpdate : 0

        let progressString = formatProgress(
            bytesDownloaded: bytesDownloaded,
            totalBytes: totalBytes,
            speed: speed,
            elapsedTime: now.timeIntervalSince(startTime)
        )

        // Clear the line and print new progress
        print("\r\u{1B}[K\(progressString)", terminator: "")
        // Force flush output (works for both macOS and Linux)
        fflush(stdout)

        lastUpdateTime = now
        lastBytesDownloaded = bytesDownloaded
    }

    /// Call when download is complete to show final message.
    func complete() {
        guard !quiet else { return }
        let totalTime = Date().timeIntervalSince(startTime)
        print("\nDownload completed in \(formatTime(totalTime))")
    }

    // MARK: - Formatting helpers

    private func formatProgress(bytesDownloaded: Int64, totalBytes: Int64?, speed: Double, elapsedTime: TimeInterval) -> String {
        let downloadedStr = formatBytes(bytesDownloaded)
        let speedStr = formatBytes(Int64(speed)) + "/s"
        let elapsedStr = formatTime(elapsedTime)

        if let totalBytes = totalBytes, totalBytes > 0 {
            let percentage = Double(bytesDownloaded) / Double(totalBytes) * 100
            let totalStr = formatBytes(totalBytes)
            let eta = speed > 0 ? formatTime(Double(totalBytes - bytesDownloaded) / speed) : "∞"

            let progressBar = createProgressBar(percentage: percentage)

            return String(format: "%@ %@ / %@ (%.1f%%) %@ ETA: %@ [%@]",
                          progressBar, downloadedStr, totalStr, percentage, speedStr, eta, elapsedStr)
        } else {
            return String(format: "%@ %@ [%@]", downloadedStr, speedStr, elapsedStr)
        }
    }

    private func createProgressBar(percentage: Double, width: Int = 30) -> String {
        let filled = Int(percentage / 100.0 * Double(width))
        let empty = width - filled

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