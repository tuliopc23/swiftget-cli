import Foundation
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import CoreFoundation
#endif

actor DownloadManager {
    private let configuration: DownloadConfiguration
    private let logger: Logger
    private let session: URLSession
    
    init(configuration: DownloadConfiguration) {
        self.configuration = configuration
        
        // Setup logger
        var logger = Logger(label: "swiftget")
        if configuration.verbose {
            logger.logLevel = .debug
        } else if configuration.quiet {
            logger.logLevel = .error
        } else {
            logger.logLevel = .info
        }
        self.logger = logger
        
        // Setup URLSession
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 300
        
        if let proxy = configuration.proxy {
            sessionConfig.connectionProxyDictionary = Self.parseProxyConfiguration(proxy)
        }
        
        self.session = URLSession(configuration: sessionConfig)
    }
    
    func downloadUrls(_ urls: [String]) async throws {
        logger.info("Starting downloads for \(urls.count) URL(s)")
        
        for url in urls {
            do {
                try await downloadSingleUrl(url)
            } catch {
                logger.error("Failed to download \(url): \(error)")
                if !configuration.quiet {
                    print("Error downloading \(url): \(error)")
                }
            }
        }
    }
    
    private func downloadSingleUrl(_ urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw DownloadError.invalidURL(urlString)
        }
        
        logger.debug("Starting download: \(urlString)")
        
        if configuration.connections > 1 {
            logger.debug("Using multi-connection downloader with \(configuration.connections) connections")
            let downloader = MultiConnectionDownloader(
                url: url,
                configuration: configuration,
                session: session,
                logger: logger
            )
            try await downloader.download()
        } else {
            let downloader = SimpleFileDownloader(
                url: url,
                configuration: configuration,
                session: session,
                logger: logger
            )
            try await downloader.download()
        }
    }
    
    private static func parseProxyConfiguration(_ proxyString: String) -> [String: Any] {
        guard let proxyURL = URL(string: proxyString) else {
            return [:]
        }
        
        var config: [String: Any] = [:]
        
        #if os(macOS)
        switch proxyURL.scheme?.lowercased() {
        case "http":
            config[kCFNetworkProxiesHTTPEnable as String] = true
            config[kCFNetworkProxiesHTTPProxy as String] = proxyURL.host
            if let port = proxyURL.port {
                config[kCFNetworkProxiesHTTPPort as String] = port
            }
        case "https":
            config[kCFNetworkProxiesHTTPSEnable as String] = true
            config[kCFNetworkProxiesHTTPSProxy as String] = proxyURL.host
            if let port = proxyURL.port {
                config[kCFNetworkProxiesHTTPSPort as String] = port
            }
        case "socks", "socks5":
            config[kCFNetworkProxiesSOCKSEnable as String] = true
            config[kCFNetworkProxiesSOCKSProxy as String] = proxyURL.host
            if let port = proxyURL.port {
                config[kCFNetworkProxiesSOCKSPort as String] = port
            }
        default:
            break
        }
        #else
        // On Linux, proxy configuration is more limited
        // Note: We can't use logger here since this is nonisolated
        print("Warning: Proxy configuration not fully supported on Linux")
        #endif
        
        return config
    }
}

enum DownloadError: Error, LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case fileSystemError(Error)
    case checksumMismatch(expected: String, actual: String)
    case unsupportedProtocol(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .fileSystemError(let error):
            return "File system error: \(error.localizedDescription)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch: expected \(expected), got \(actual)"
        case .unsupportedProtocol(let scheme):
            return "Unsupported protocol: \(scheme)"
        }
    }
}