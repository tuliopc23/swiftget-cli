import Foundation

class DownloadTask {
    let url: URL
    let destination: URL
    var task: URLSessionDownloadTask?
    var progress: Double = 0.0
    var isPaused: Bool = false
    var isCompleted: Bool = false
    var resumeData: Data?
    
    init(url: URL, destination: URL) {
        self.url = url
        self.destination = destination
    }
}

class DownloadManager: NSObject, URLSessionDownloadDelegate {
    private var queue: [DownloadTask] = []
    private var activeTasks: [DownloadTask] = []
    private let maxParallelDownloads: Int
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    init(maxParallelDownloads: Int = 2) {
        self.maxParallelDownloads = maxParallelDownloads
    }
    
    func addDownload(url: URL, destination: URL) {
        let task = DownloadTask(url: url, destination: destination)
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
}