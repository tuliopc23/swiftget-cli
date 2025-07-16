import Foundation
import CommonCrypto

class DownloadTask {
    let url: URL
    let destination: URL
    var task: URLSessionDownloadTask?
    var progress: Double = 0.0
    var isPaused: Bool = false
    var isCompleted: Bool = false
    var resumeData: Data?
    var retryCount: Int = 0
    var maxRetries: Int = 3
    var expectedChecksum: String?
    var checksumAlgorithm: String = "sha256"
    
    init(url: URL, destination: URL) {
        self.url = url
        self.destination = destination
    }
}

class DownloadSegment {
    let url: URL
    let destination: URL
    let range: Range<Int64>
    var task: URLSessionDataTask?
    var data: Data?
    var isCompleted: Bool = false
    var mirror: URL?
    var retryCount: Int = 0
    var maxRetries: Int = 3
    var expectedChecksum: String?
    var checksumAlgorithm: String = "sha256"
    
    init(url: URL, destination: URL, range: Range<Int64>, mirror: URL? = nil) {
        self.url = url
        self.destination = destination
        self.range = range
        self.mirror = mirror
    }
}

class DownloadManager: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate {
    private var queue: [DownloadTask] = []
    private var activeTasks: [DownloadTask] = []
    private let maxParallelDownloads: Int
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private var segmentedDownloads: [URL: [DownloadSegment]] = [:]
    private var segmentCompletionHandlers: [URL: (() -> Void)] = [:]
    
    init(maxParallelDownloads: Int = 2) {
        self.maxParallelDownloads = maxParallelDownloads
    }
    
    func addDownload(url: URL, destination: URL, maxRetries: Int = 3, expectedChecksum: String? = nil, checksumAlgorithm: String = "sha256") {
        let task = DownloadTask(url: url, destination: destination)
        task.maxRetries = maxRetries
        task.expectedChecksum = expectedChecksum
        task.checksumAlgorithm = checksumAlgorithm
        queue.append(task)
        startNextDownloads()
    }
    
    func pauseDownload(url: URL) {
        if let task = activeTasks.first(where: { $0.url == url }), let downloadTask = task.task {
            downloadTask.cancel(byProducingResumeData: { data in
                task.resumeData = data
                task.isPaused = true
                self.activeTasks.removeAll { $0.url == url }
                self.queue.append(task)
                self.startNextDownloads()
            })
        }
    }
    
    func resumeDownload(url: URL) {
        if let task = queue.first(where: { $0.url == url && $0.isPaused }), let resumeData = task.resumeData {
            task.task = session.downloadTask(withResumeData: resumeData)
            task.isPaused = false
            task.resumeData = nil
            activeTasks.append(task)
            queue.removeAll { $0.url == url }
            task.task?.resume()
        }
    }
    
    func startNextDownloads() {
        while activeTasks.count < maxParallelDownloads, let next = queue.first(where: { !$0.isPaused }) {
            let downloadTask = session.downloadTask(with: next.url)
            next.task = downloadTask
            activeTasks.append(next)
            queue.removeAll { $0 === next }
            downloadTask.resume()
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let url = downloadTask.originalRequest?.url,
              let task = activeTasks.first(where: { $0.url == url }) else { return }
        if totalBytesExpectedToWrite > 0 {
            task.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            print("Progress for \(url.lastPathComponent): \(Int(task.progress * 100))%")
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let url = downloadTask.originalRequest?.url,
              let task = activeTasks.first(where: { $0.url == url }) else { return }
        do {
            try FileManager.default.moveItem(at: location, to: task.destination)
            print("Downloaded \(url.lastPathComponent) to \(task.destination.path)")
            
            // Verify checksum if provided
            if let expectedChecksum = task.expectedChecksum {
                do {
                    let fileData = try Data(contentsOf: task.destination)
                    _ = verifyChecksum(data: fileData, expected: expectedChecksum, algorithm: task.checksumAlgorithm)
                } catch {
                    print("Failed to read file for checksum verification: \(error)")
                }
            }
        } catch {
            print("Failed to move file: \(error)")
        }
        task.isCompleted = true
        activeTasks.removeAll { $0.url == url }
        startNextDownloads()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError?, let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            guard let url = task.originalRequest?.url,
                  let downloadTask = activeTasks.first(where: { $0.url == url }) else { return }
            downloadTask.resumeData = resumeData
            downloadTask.isPaused = true
            print("Download paused for \(url.lastPathComponent)")
        } else if let error = error {
            print("Download failed: \(error.localizedDescription)")
        }
    }
    
    func listDownloads() {
        print("Active downloads:")
        for task in activeTasks {
            print("- \(task.url.lastPathComponent): \(Int(task.progress * 100))%")
        }
        print("Queued downloads:")
        for task in queue {
            print("- \(task.url.lastPathComponent) (paused: \(task.isPaused))")
        }
    }
    
    // New: Segmented download
    func addSegmentedDownload(url: URL, destination: URL, segments: Int = 4, mirrors: [URL] = [], maxRetries: Int = 3, expectedChecksum: String? = nil, checksumAlgorithm: String = "sha256") {
        // Get file size first
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let headTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let response = response as? HTTPURLResponse,
                  let contentLength = response.value(forHTTPHeaderField: "Content-Length"),
                  let fileSize = Int64(contentLength) else {
                print("Failed to get file size for segmented download.")
                return
            }
            let segmentSize = fileSize / Int64(segments)
            var downloadSegments: [DownloadSegment] = []
            for i in 0..<segments {
                let start = Int64(i) * segmentSize
                let end = (i == segments - 1) ? fileSize - 1 : (start + segmentSize - 1)
                let range = start..<(end + 1)
                // Use mirrors in round-robin if provided
                let mirror = mirrors.isEmpty ? nil : mirrors[i % mirrors.count]
                let segment = DownloadSegment(url: mirror ?? url, destination: destination, range: range, mirror: mirror)
                segment.retryCount = 0
                segment.maxRetries = maxRetries
                segment.expectedChecksum = expectedChecksum
                segment.checksumAlgorithm = checksumAlgorithm
                downloadSegments.append(segment)
            }
            self.segmentedDownloads[url] = downloadSegments
            self.downloadSegments(url: url, destination: destination)
        }
        headTask.resume()
    }

    private func downloadSegments(url: URL, destination: URL) {
        guard let segments = segmentedDownloads[url] else { return }
        let group = DispatchGroup()
        for segment in segments {
            group.enter()
            var request = URLRequest(url: segment.url)
            request.addValue("bytes=\(segment.range.lowerBound)-\(segment.range.upperBound - 1)", forHTTPHeaderField: "Range")
            let dataTask = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { group.leave(); return }
                if let data = data {
                    segment.data = data
                    segment.isCompleted = true
                    group.leave()
                } else {
                    if segment.retryCount < segment.maxRetries {
                        let delay = pow(2.0, Double(segment.retryCount))
                        print("Segment failed, retrying (\(segment.retryCount+1)/\(segment.maxRetries)) in \(delay)s: \(error?.localizedDescription ?? "unknown error")")
                        segment.retryCount += 1
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            self.downloadSegment(segment: segment, group: group)
                        }
                    } else {
                        print("Segment download failed after \(segment.maxRetries) attempts: \(error?.localizedDescription ?? "unknown error")")
                        group.leave()
                    }
                }
            }
            segment.task = dataTask
            dataTask.resume()
        }
        group.notify(queue: .main) {
            self.mergeSegments(url: url, destination: destination)
        }
    }

    private func downloadSegment(segment: DownloadSegment, group: DispatchGroup) {
        var request = URLRequest(url: segment.url)
        request.addValue("bytes=\(segment.range.lowerBound)-\(segment.range.upperBound - 1)", forHTTPHeaderField: "Range")
        let dataTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { group.leave(); return }
            if let data = data {
                segment.data = data
                segment.isCompleted = true
                group.leave()
            } else {
                if segment.retryCount < segment.maxRetries {
                    let delay = pow(2.0, Double(segment.retryCount))
                    print("Segment failed, retrying (\(segment.retryCount+1)/\(segment.maxRetries)) in \(delay)s: \(error?.localizedDescription ?? "unknown error")")
                    segment.retryCount += 1
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.downloadSegment(segment: segment, group: group)
                    }
                } else {
                    print("Segment download failed after \(segment.maxRetries) attempts: \(error?.localizedDescription ?? "unknown error")")
                    group.leave()
                }
            }
        }
        segment.task = dataTask
        dataTask.resume()
    }

    private func mergeSegments(url: URL, destination: URL) {
        guard let segments = segmentedDownloads[url] else { return }
        let fileURL = destination
        do {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            try fileHandle.truncate(atOffset: 0)
            for segment in segments.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                if let data = segment.data {
                    fileHandle.write(data)
                }
            }
            try fileHandle.close()
            print("Segmented download complete: \(fileURL.path)")
            
            // Verify checksum if provided
            if let expectedChecksum = segments.first?.expectedChecksum, let algorithm = segments.first?.checksumAlgorithm {
                do {
                    let fileData = try Data(contentsOf: fileURL)
                    _ = verifyChecksum(data: fileData, expected: expectedChecksum, algorithm: algorithm)
                } catch {
                    print("Failed to read file for checksum verification: \(error)")
                }
            }
        } catch {
            // If file doesn't exist, create it
            do {
                var allData = Data()
                for segment in segments.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                    if let data = segment.data {
                        allData.append(data)
                    }
                }
                try allData.write(to: fileURL)
                print("Segmented download complete: \(fileURL.path)")
            } catch {
                print("Failed to merge segments: \(error)")
            }
        }
        segmentedDownloads.removeValue(forKey: url)
        segmentCompletionHandlers[url]?()
    }
    
    private func calculateChecksum(data: Data, algorithm: String) -> String {
        switch algorithm.lowercased() {
        case "sha1":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            data.withUnsafeBytes { bytes in
                _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &digest)
            }
            return digest.map { String(format: "%02hhx", $0) }.joined()
        case "sha256":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            data.withUnsafeBytes { bytes in
                _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
            }
            return digest.map { String(format: "%02hhx", $0) }.joined()
        case "md5":
            var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            data.withUnsafeBytes { bytes in
                _ = CC_MD5(bytes.baseAddress, CC_LONG(data.count), &digest)
            }
            return digest.map { String(format: "%02hhx", $0) }.joined()
        default:
            return ""
        }
    }
    
    private func verifyChecksum(data: Data, expected: String, algorithm: String) -> Bool {
        let calculated = calculateChecksum(data: data, algorithm: algorithm)
        let matches = calculated.lowercased() == expected.lowercased()
        if matches {
            print("Checksum verification passed (\(algorithm))")
        } else {
            print("Checksum verification failed (\(algorithm))")
            print("Expected: \(expected)")
            print("Calculated: \(calculated)")
        }
        return matches
    }
}

#if canImport(Socket)
import Socket
#endif

extension DownloadManager {
    // Basic FTP download (placeholder, anonymous login)
    func addFTPDownload(url: URL, destination: URL, username: String = "anonymous", password: String = "") {
#if canImport(Socket)
        guard let host = url.host, let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            print("Invalid FTP URL")
            return
        }
        do {
            let socket = try Socket.create()
            try socket.connect(to: host, port: 21)
            func send(_ cmd: String) {
                try? socket.write(from: cmd + "\r\n")
            }
            func readResponse() -> String {
                var data = Data()
                _ = try? socket.read(into: &data)
                return String(data: data, encoding: .utf8) ?? ""
            }
            _ = readResponse() // Welcome
            send("USER \(username)")
            _ = readResponse()
            send("PASS \(password)")
            _ = readResponse()
            send("TYPE I")
            _ = readResponse()
            send("PASV")
            let pasvResp = readResponse()
            // Parse PASV response for data port
            let numbers = pasvResp.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            guard numbers.count >= 6 else { print("Failed PASV parse"); return }
            let dataPort = numbers[4] * 256 + numbers[5]
            let dataSocket = try Socket.create()
            try dataSocket.connect(to: host, port: Int32(dataPort))
            send("RETR \(path)")
            _ = readResponse()
            var fileData = Data()
            _ = try? dataSocket.read(into: &fileData)
            try fileData.write(to: destination)
            print("FTP download complete: \(destination.path)")
            dataSocket.close()
            socket.close()
        } catch {
            print("FTP download failed: \(error)")
        }
#else
        print("FTP support requires BlueSocket and a Swift toolchain.")
#endif
    }
}