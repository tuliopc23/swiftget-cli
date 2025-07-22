import Foundation

struct DownloadConfiguration {
    let directory: String?
    let output: String?
    let connections: Int
    let maxSpeed: Int?
    let userAgent: String?
    let headers: [String: String]
    let proxy: String?
    let checksum: ChecksumInfo?
    let continueDownload: Bool
    let quiet: Bool
    let verbose: Bool
    let showProgress: Bool
    let checkCertificate: Bool
    let extract: Bool
    let openInFinder: Bool
    
    var effectiveDirectory: URL {
        if let directory = directory {
            return URL(fileURLWithPath: directory)
        } else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
    }
    
    var effectiveUserAgent: String {
        return userAgent ?? "SwiftGet/2.0.0 (macOS)"
    }
}

enum ChecksumAlgorithm {
    case md5
    case sha1
    case sha256
}

struct ChecksumInfo {
    let algorithm: ChecksumAlgorithm
    let hash: String
}