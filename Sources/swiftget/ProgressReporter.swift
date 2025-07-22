import Foundation
#if os(Linux)
import Glibc
#endif

class ProgressReporter {
    private let url: URL
    private let quiet: Bool
    private let startTime: Date
    private var lastUpdateTime: Date
    private var lastBytesDownloaded: Int64 = 0
    
    init(url: URL, quiet: Bool) {
        self.url = url
        self.quiet = quiet
        self.startTime = Date()
        self.lastUpdateTime = Date()
        
        if !quiet {
            print("Downloading: \(url.lastPathComponent)")
        }
    }
    
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
        // Force flush output
        FileHandle.standardOutput.synchronizeFile()
        
        lastUpdateTime = now
        lastBytesDownloaded = bytesDownloaded
    }
    
    func complete() {
        guard !quiet else { return }
        
        let totalTime = Date().timeIntervalSince(startTime)
        print("\nDownload completed in \(formatTime(totalTime))")
    }
    
    private func formatProgress(bytesDownloaded: Int64, totalBytes: Int64?, speed: Double, elapsedTime: TimeInterval) -> String {
        let downloadedStr = formatBytes(bytesDownloaded)
        let speedStr = formatBytes(Int64(speed)) + "/s"
        let elapsedStr = formatTime(elapsedTime)
        
        if let totalBytes = totalBytes, totalBytes > 0 {
            let percentage = Double(bytesDownloaded) / Double(totalBytes) * 100
            let totalStr = formatBytes(totalBytes)
            let eta = speed > 0 ? formatTime(Double(totalBytes - bytesDownloaded) / speed) : "∞"
            
            let progressBar = createProgressBar(percentage: percentage)
            
            return String(format: "%@ %@ / %@ (%.1f%%) %@ ETA: %s [%@]",
                         progressBar, downloadedStr, totalStr, percentage, speedStr, eta, elapsedStr)
        } else {
            return String(format: "%@ %@ [%@]", downloadedStr, speedStr, elapsedStr)
        }
    }
    
    private func createProgressBar(percentage: Double, width: Int = 30) -> String {
        let filled = Int(percentage / 100.0 * Double(width))
        let empty = width - filled
        
        let filledBar = String(repeating: "█", count: filled)
        let emptyBar = String(repeating: "░", count: empty)
        
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