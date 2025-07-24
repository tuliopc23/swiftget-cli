import Foundation
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Connection pool for efficient HTTP connection reuse and management
actor ConnectionPool {
    private let logger: Logger
    private let maxConnections: Int
    private let connectionTimeout: TimeInterval
    private let keepAliveTimeout: TimeInterval
    
    private var availableConnections: [PooledConnection] = []
    private var activeConnections: Set<UUID> = []
    private var connectionStats: ConnectionStats = ConnectionStats()
    
    struct PooledConnection {
        let id: UUID
        let session: URLSession
        let createdAt: Date
        let lastUsed: Date
        let host: String
        let port: Int
        
        var isExpired: Bool {
            Date().timeIntervalSince(lastUsed) > 300 // 5 minutes
        }
        
        var age: TimeInterval {
            Date().timeIntervalSince(createdAt)
        }
    }
    
    struct ConnectionStats {
        var totalConnections: Int = 0
        var activeConnections: Int = 0
        var reuseCount: Int = 0
        var timeoutCount: Int = 0
        var errorCount: Int = 0
        
        mutating func recordReuse() {
            reuseCount += 1
        }
        
        mutating func recordTimeout() {
            timeoutCount += 1
        }
        
        mutating func recordError() {
            errorCount += 1
        }
        
        var reuseRate: Double {
            guard totalConnections > 0 else { return 0 }
            return Double(reuseCount) / Double(totalConnections)
        }
        
        var formattedStats: String {
            return """
            Connection Pool Stats:
              Total: \(totalConnections)
              Active: \(activeConnections)
              Reuse Rate: \(String(format: "%.1f", reuseRate * 100))%
              Timeouts: \(timeoutCount)
              Errors: \(errorCount)
            """
        }
    }
    
    init(maxConnections: Int = 16, connectionTimeout: TimeInterval = 30.0, keepAliveTimeout: TimeInterval = 300.0, logger: Logger) {
        self.maxConnections = maxConnections
        self.connectionTimeout = connectionTimeout
        self.keepAliveTimeout = keepAliveTimeout
        self.logger = logger
    }
    
    /// Get a connection from the pool or create a new one
    func getConnection(for url: URL) -> URLSession {
        let host = url.host ?? "unknown"
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        
        // Try to reuse an existing connection
        if let existingConnection = findAvailableConnection(host: host, port: port) {
            connectionStats.recordReuse()
            activeConnections.insert(existingConnection.id)
            logger.debug("Reusing connection for \(host):\(port)")
            return existingConnection.session
        }
        
        // Create a new connection if under limit
        if availableConnections.count + activeConnections.count < maxConnections {
            let newConnection = createConnection(host: host, port: port)
            activeConnections.insert(newConnection.id)
            connectionStats.totalConnections += 1
            logger.debug("Created new connection for \(host):\(port)")
            return newConnection.session
        }
        
        // Pool is full, create a temporary session
        logger.warning("Connection pool full, creating temporary session")
        return createTemporarySession()
    }
    
    /// Return a connection to the pool
    func returnConnection(_ session: URLSession) {
        // Find the connection by session
        if let connectionIndex = availableConnections.firstIndex(where: { $0.session === session }) {
            let connection = availableConnections[connectionIndex]
            activeConnections.remove(connection.id)
            
            // Update last used time
            availableConnections[connectionIndex] = PooledConnection(
                id: connection.id,
                session: connection.session,
                createdAt: connection.createdAt,
                lastUsed: Date(),
                host: connection.host,
                port: connection.port
            )
            
            logger.debug("Returned connection to pool")
        }
    }
    
    /// Clean up expired connections
    func cleanupExpiredConnections() {
        let beforeCount = availableConnections.count
        
        availableConnections.removeAll { connection in
            if connection.isExpired {
                connection.session.invalidateAndCancel()
                activeConnections.remove(connection.id)
                return true
            }
            return false
        }
        
        let removedCount = beforeCount - availableConnections.count
        if removedCount > 0 {
            logger.debug("Cleaned up \(removedCount) expired connections")
        }
    }
    
    /// Get current pool statistics
    func getStats() -> ConnectionStats {
        var stats = connectionStats
        stats.activeConnections = activeConnections.count
        return stats
    }
    
    /// Shutdown the pool and invalidate all connections
    func shutdown() {
        logger.info("Shutting down connection pool")
        
        for connection in availableConnections {
            connection.session.invalidateAndCancel()
        }
        
        availableConnections.removeAll()
        activeConnections.removeAll()
        connectionStats = ConnectionStats()
    }
    
    // MARK: - Private Methods
    
    private func findAvailableConnection(host: String, port: Int) -> PooledConnection? {
        // Clean up expired connections first
        cleanupExpiredConnections()
        
        // Find a matching available connection
        guard let index = availableConnections.firstIndex(where: { connection in
            connection.host == host && 
            connection.port == port && 
            !connection.isExpired &&
            !activeConnections.contains(connection.id)
        }) else {
            return nil
        }
        
        return availableConnections.remove(at: index)
    }
    
    private func createConnection(host: String, port: Int) -> PooledConnection {
        let config = URLSessionConfiguration.default
        
        // Optimize for performance
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = connectionTimeout
        config.timeoutIntervalForResource = connectionTimeout * 2
        
        // Enable HTTP/2 and connection reuse
        config.httpShouldUsePipelining = true
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        
        // Connection keep-alive
        config.httpAdditionalHeaders = [
            "Connection": "keep-alive",
            "Keep-Alive": "timeout=\(Int(keepAliveTimeout))"
        ]
        
        let session = URLSession(configuration: config)
        
        return PooledConnection(
            id: UUID(),
            session: session,
            createdAt: Date(),
            lastUsed: Date(),
            host: host,
            port: port
        )
    }
    
    private func createTemporarySession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = connectionTimeout
        config.timeoutIntervalForResource = connectionTimeout * 2
        config.httpShouldUsePipelining = true
        
        return URLSession(configuration: config)
    }
}

/// Connection pool manager for coordinating multiple pools
actor ConnectionPoolManager {
    private let logger: Logger
    private var pools: [String: ConnectionPool] = [:]
    private let maxPoolsPerHost: Int = 4
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    /// Get a connection pool for a specific host
    func getPool(for url: URL) -> ConnectionPool {
        let host = url.host ?? "unknown"
        
        if let existingPool = pools[host] {
            return existingPool
        }
        
        // Create new pool for this host
        let newPool = ConnectionPool(logger: logger)
        pools[host] = newPool
        
        logger.debug("Created connection pool for host: \(host)")
        return newPool
    }
    
    /// Get aggregated statistics from all pools
    func getAggregatedStats() -> ConnectionPool.ConnectionStats {
        var aggregated = ConnectionPool.ConnectionStats()
        
        for pool in pools.values {
            let stats = pool.getStats()
            aggregated.totalConnections += stats.totalConnections
            aggregated.activeConnections += stats.activeConnections
            aggregated.reuseCount += stats.reuseCount
            aggregated.timeoutCount += stats.timeoutCount
            aggregated.errorCount += stats.errorCount
        }
        
        return aggregated
    }
    
    /// Clean up all pools
    func cleanupAllPools() {
        for pool in pools.values {
            pool.cleanupExpiredConnections()
        }
    }
    
    /// Shutdown all pools
    func shutdown() {
        logger.info("Shutting down all connection pools")
        
        for pool in pools.values {
            pool.shutdown()
        }
        
        pools.removeAll()
    }
}
