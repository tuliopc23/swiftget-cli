import Foundation

/// Bandwidth allocation token that represents an allocation grant from the GlobalBandwidthManager
/// This token is used to track and manage bandwidth usage for individual downloads
struct BandwidthToken: Sendable {
    
    // MARK: - Core Properties
    
    /// Unique identifier for this bandwidth allocation
    let id: UUID
    
    /// The download ID this token is allocated to
    let downloadId: UUID
    
    /// Amount of bandwidth allocated in bytes per second
    let allocatedBandwidth: Int64
    
    /// Priority level of this allocation
    let priority: BandwidthPriority
    
    /// Type of download this token supports
    let downloadType: DownloadType
    
    /// Timestamp when this token was allocated
    let allocationTime: Date
    
    /// Last time usage was reported for this token
    let lastUsageUpdate: Date
    
    /// Last reported actual usage in bytes per second
    let lastReportedUsage: Int64?
    
    /// Expiration time for this token (if applicable)
    let expirationTime: Date?
    
    /// Additional metadata for the token
    let metadata: BandwidthTokenMetadata
    
    // MARK: - Computed Properties
    
    /// Age of this token in seconds
    var age: TimeInterval {
        return Date().timeIntervalSince(allocationTime)
    }
    
    /// Time since last usage update in seconds
    var timeSinceLastUpdate: TimeInterval {
        return Date().timeIntervalSince(lastUsageUpdate)
    }
    
    /// Whether this token has expired
    var isExpired: Bool {
        guard let expirationTime = expirationTime else { return false }
        return Date() > expirationTime
    }
    
    /// Utilization ratio (actual usage / allocated bandwidth)
    var utilizationRatio: Double {
        guard let usage = lastReportedUsage, allocatedBandwidth > 0 else { return 0.0 }
        return min(1.0, Double(usage) / Double(allocatedBandwidth))
    }
    
    /// Whether this token is currently under-utilized
    var isUnderUtilized: Bool {
        return utilizationRatio < 0.5 // Less than 50% utilization
    }
    
    /// Whether this token is over-utilized (attempting to use more than allocated)
    var isOverUtilized: Bool {
        return utilizationRatio > 1.0
    }
    
    /// Formatted bandwidth allocation as human-readable string
    var formattedBandwidth: String {
        return ByteCountFormatter.string(fromByteCount: allocatedBandwidth, countStyle: .binary) + "/s"
    }
    
    // MARK: - Initialization
    
    init(
        id: UUID = UUID(),
        downloadId: UUID,
        allocatedBandwidth: Int64,
        priority: BandwidthPriority,
        downloadType: DownloadType = .general,
        allocationTime: Date = Date(),
        lastUsageUpdate: Date = Date(),
        lastReportedUsage: Int64? = nil,
        expirationTime: Date? = nil,
        metadata: BandwidthTokenMetadata = BandwidthTokenMetadata()
    ) {
        self.id = id
        self.downloadId = downloadId
        self.allocatedBandwidth = allocatedBandwidth
        self.priority = priority
        self.downloadType = downloadType
        self.allocationTime = allocationTime
        self.lastUsageUpdate = lastUsageUpdate
        self.lastReportedUsage = lastReportedUsage
        self.expirationTime = expirationTime
        self.metadata = metadata
    }
    
    // MARK: - Token Modification Methods
    
    /// Create a new token with updated usage information
    /// - Parameters:
    ///   - actualUsage: The actual bandwidth usage in bytes per second
    ///   - timestamp: When this usage was measured (defaults to now)
    /// - Returns: New token with updated usage information
    func withUpdatedUsage(actualUsage: Int64, timestamp: Date = Date()) -> BandwidthToken {
        return BandwidthToken(
            id: id,
            downloadId: downloadId,
            allocatedBandwidth: allocatedBandwidth,
            priority: priority,
            downloadType: downloadType,
            allocationTime: allocationTime,
            lastUsageUpdate: timestamp,
            lastReportedUsage: actualUsage,
            expirationTime: expirationTime,
            metadata: metadata.withUpdatedStats(usage: actualUsage, timestamp: timestamp)
        )
    }
    
    /// Create a new token with a different bandwidth allocation
    /// - Parameter newAllocation: New bandwidth allocation in bytes per second
    /// - Returns: New token with updated allocation
    func withNewAllocation(_ newAllocation: Int64) -> BandwidthToken {
        let updatedMetadata = metadata.withAllocationChange(
            oldAllocation: allocatedBandwidth,
            newAllocation: newAllocation
        )
        
        return BandwidthToken(
            id: id,
            downloadId: downloadId,
            allocatedBandwidth: newAllocation,
            priority: priority,
            downloadType: downloadType,
            allocationTime: allocationTime,
            lastUsageUpdate: Date(),
            lastReportedUsage: lastReportedUsage,
            expirationTime: expirationTime,
            metadata: updatedMetadata
        )
    }
    
    /// Create a new token with updated priority
    /// - Parameter newPriority: New priority level
    /// - Returns: New token with updated priority
    func withUpdatedPriority(_ newPriority: BandwidthPriority) -> BandwidthToken {
        return BandwidthToken(
            id: id,
            downloadId: downloadId,
            allocatedBandwidth: allocatedBandwidth,
            priority: newPriority,
            downloadType: downloadType,
            allocationTime: allocationTime,
            lastUsageUpdate: lastUsageUpdate,
            lastReportedUsage: lastReportedUsage,
            expirationTime: expirationTime,
            metadata: metadata
        )
    }
    
    /// Create a new token with extended expiration time
    /// - Parameter extensionTime: Time interval to extend the expiration
    /// - Returns: New token with extended expiration
    func withExtendedExpiration(_ extensionTime: TimeInterval) -> BandwidthToken {
        let newExpiration = (expirationTime ?? Date()).addingTimeInterval(extensionTime)
        
        return BandwidthToken(
            id: id,
            downloadId: downloadId,
            allocatedBandwidth: allocatedBandwidth,
            priority: priority,
            downloadType: downloadType,
            allocationTime: allocationTime,
            lastUsageUpdate: lastUsageUpdate,
            lastReportedUsage: lastReportedUsage,
            expirationTime: newExpiration,
            metadata: metadata
        )
    }
    
    // MARK: - Token Validation
    
    /// Validate that this token is still valid for use
    /// - Parameters:
    ///   - maxAge: Maximum age allowed for tokens (optional)
    ///   - maxInactivity: Maximum time allowed since last update (optional)
    /// - Returns: Validation result with details
    func validate(maxAge: TimeInterval? = nil, maxInactivity: TimeInterval? = nil) -> TokenValidationResult {
        var issues: [String] = []
        
        // Check expiration
        if isExpired {
            issues.append("Token has expired")
        }
        
        // Check age limit
        if let maxAge = maxAge, age > maxAge {
            issues.append("Token exceeds maximum age of \(Int(maxAge))s")
        }
        
        // Check inactivity
        if let maxInactivity = maxInactivity, timeSinceLastUpdate > maxInactivity {
            issues.append("Token has been inactive for \(Int(timeSinceLastUpdate))s")
        }
        
        // Check bandwidth allocation
        if allocatedBandwidth <= 0 {
            issues.append("Invalid bandwidth allocation: \(allocatedBandwidth)")
        }
        
        let isValid = issues.isEmpty
        return TokenValidationResult(
            isValid: isValid,
            issues: issues,
            token: self
        )
    }
    
    // MARK: - Usage Analysis
    
    /// Analyze usage patterns for this token
    /// - Returns: Usage analysis with recommendations
    func analyzeUsage() -> TokenUsageAnalysis {
        guard lastReportedUsage != nil else {
            return TokenUsageAnalysis(
                token: self,
                efficiency: 0.0,
                recommendation: .awaitingFirstUsageReport,
                analysis: "No usage data available yet"
            )
        }
        
        let efficiency = utilizationRatio
        let recommendation: UsageRecommendation
        let analysis: String
        
        switch efficiency {
        case 0.0..<0.3:
            recommendation = .reduceAllocation
            analysis = "Very low utilization (\(String(format: "%.1f", efficiency * 100))%). Consider reducing allocation."
            
        case 0.3..<0.7:
            recommendation = .maintainCurrent
            analysis = "Good utilization (\(String(format: "%.1f", efficiency * 100))%). Current allocation is appropriate."
            
        case 0.7..<1.0:
            recommendation = .monitorClosely
            analysis = "High utilization (\(String(format: "%.1f", efficiency * 100))%). Monitor for potential need to increase allocation."
            
        case 1.0...:
            recommendation = .increaseAllocation
            analysis = "Over-utilization (\(String(format: "%.1f", efficiency * 100))%). Consider increasing allocation."
            
        default:
            recommendation = .maintainCurrent
            analysis = "Normal utilization"
        }
        
        return TokenUsageAnalysis(
            token: self,
            efficiency: efficiency,
            recommendation: recommendation,
            analysis: analysis
        )
    }
}

// MARK: - Supporting Types

/// Metadata associated with a bandwidth token
struct BandwidthTokenMetadata: Sendable {
    let createdBy: String
    let purpose: String
    let tags: Set<String>
    let allocationHistory: [AllocationChange]
    let usageHistory: [UsageSnapshot]
    let maxHistorySize: Int
    
    init(
        createdBy: String = "GlobalBandwidthManager",
        purpose: String = "download",
        tags: Set<String> = [],
        allocationHistory: [AllocationChange] = [],
        usageHistory: [UsageSnapshot] = [],
        maxHistorySize: Int = 20
    ) {
        self.createdBy = createdBy
        self.purpose = purpose
        self.tags = tags
        self.allocationHistory = allocationHistory
        self.usageHistory = usageHistory
        self.maxHistorySize = maxHistorySize
    }
    
    /// Create metadata with updated usage statistics
    func withUpdatedStats(usage: Int64, timestamp: Date) -> BandwidthTokenMetadata {
        var newUsageHistory = usageHistory
        newUsageHistory.append(UsageSnapshot(usage: usage, timestamp: timestamp))
        
        // Keep only the most recent entries
        if newUsageHistory.count > maxHistorySize {
            newUsageHistory.removeFirst(newUsageHistory.count - maxHistorySize)
        }
        
        return BandwidthTokenMetadata(
            createdBy: createdBy,
            purpose: purpose,
            tags: tags,
            allocationHistory: allocationHistory,
            usageHistory: newUsageHistory,
            maxHistorySize: maxHistorySize
        )
    }
    
    /// Create metadata with allocation change record
    func withAllocationChange(oldAllocation: Int64, newAllocation: Int64) -> BandwidthTokenMetadata {
        var newAllocationHistory = allocationHistory
        newAllocationHistory.append(AllocationChange(
            oldAllocation: oldAllocation,
            newAllocation: newAllocation,
            timestamp: Date()
        ))
        
        // Keep only the most recent entries
        if newAllocationHistory.count > maxHistorySize {
            newAllocationHistory.removeFirst(newAllocationHistory.count - maxHistorySize)
        }
        
        return BandwidthTokenMetadata(
            createdBy: createdBy,
            purpose: purpose,
            tags: tags,
            allocationHistory: newAllocationHistory,
            usageHistory: usageHistory,
            maxHistorySize: maxHistorySize
        )
    }
}

/// Record of bandwidth allocation changes
struct AllocationChange: Sendable {
    let oldAllocation: Int64
    let newAllocation: Int64
    let timestamp: Date
    
    var changeAmount: Int64 {
        return newAllocation - oldAllocation
    }
    
    var changeRatio: Double {
        guard oldAllocation > 0 else { return newAllocation > 0 ? Double.infinity : 0.0 }
        return Double(newAllocation) / Double(oldAllocation)
    }
}

/// Snapshot of bandwidth usage at a point in time
struct UsageSnapshot: Sendable {
    let usage: Int64
    let timestamp: Date
}

/// Result of token validation
struct TokenValidationResult: Sendable {
    let isValid: Bool
    let issues: [String]
    let token: BandwidthToken
    
    var hasIssues: Bool {
        return !issues.isEmpty
    }
}

/// Analysis of token usage patterns
struct TokenUsageAnalysis: Sendable {
    let token: BandwidthToken
    let efficiency: Double
    let recommendation: UsageRecommendation
    let analysis: String
}

/// Recommendations for bandwidth token usage
enum UsageRecommendation: String, CaseIterable, Sendable {
    case awaitingFirstUsageReport = "awaiting_first_usage"
    case reduceAllocation = "reduce_allocation"
    case maintainCurrent = "maintain_current"
    case monitorClosely = "monitor_closely"
    case increaseAllocation = "increase_allocation"
    
    var description: String {
        switch self {
        case .awaitingFirstUsageReport:
            return "Awaiting first usage report"
        case .reduceAllocation:
            return "Consider reducing bandwidth allocation"
        case .maintainCurrent:
            return "Maintain current allocation"
        case .monitorClosely:
            return "Monitor usage closely"
        case .increaseAllocation:
            return "Consider increasing bandwidth allocation"
        }
    }
}

// MARK: - Token Collections and Management

/// Collection of bandwidth tokens with management utilities
struct BandwidthTokenCollection: Sendable {
    private let tokens: [UUID: BandwidthToken]
    
    init(tokens: [BandwidthToken] = []) {
        self.tokens = Dictionary(uniqueKeysWithValues: tokens.map { ($0.id, $0) })
    }
    
    /// All tokens in the collection
    var allTokens: [BandwidthToken] {
        return Array(tokens.values)
    }
    
    /// Active (non-expired) tokens
    var activeTokens: [BandwidthToken] {
        return tokens.values.filter { !$0.isExpired }
    }
    
    /// Expired tokens
    var expiredTokens: [BandwidthToken] {
        return tokens.values.filter { $0.isExpired }
    }
    
    /// Total allocated bandwidth across all active tokens
    var totalAllocatedBandwidth: Int64 {
        return activeTokens.reduce(0) { $0 + $1.allocatedBandwidth }
    }
    
    /// Average utilization across all tokens with usage data
    var averageUtilization: Double {
        let tokensWithUsage = activeTokens.filter { $0.lastReportedUsage != nil }
        guard !tokensWithUsage.isEmpty else { return 0.0 }
        
        let totalUtilization = tokensWithUsage.reduce(0.0) { $0 + $1.utilizationRatio }
        return totalUtilization / Double(tokensWithUsage.count)
    }
    
    /// Get token by ID
    func token(withId id: UUID) -> BandwidthToken? {
        return tokens[id]
    }
    
    /// Get tokens for a specific download
    func tokens(forDownload downloadId: UUID) -> [BandwidthToken] {
        return tokens.values.filter { $0.downloadId == downloadId }
    }
    
    /// Get tokens with specific priority
    func tokens(withPriority priority: BandwidthPriority) -> [BandwidthToken] {
        return tokens.values.filter { $0.priority == priority }
    }
    
    /// Get under-utilized tokens
    func underUtilizedTokens() -> [BandwidthToken] {
        return activeTokens.filter { $0.isUnderUtilized }
    }
    
    /// Get over-utilized tokens
    func overUtilizedTokens() -> [BandwidthToken] {
        return activeTokens.filter { $0.isOverUtilized }
    }
    
    /// Create a new collection with an added token
    func adding(_ token: BandwidthToken) -> BandwidthTokenCollection {
        var newTokens = tokens
        newTokens[token.id] = token
        return BandwidthTokenCollection(tokens: Array(newTokens.values))
    }
    
    /// Create a new collection with a removed token
    func removing(tokenId: UUID) -> BandwidthTokenCollection {
        var newTokens = tokens
        newTokens.removeValue(forKey: tokenId)
        return BandwidthTokenCollection(tokens: Array(newTokens.values))
    }
    
    /// Create a new collection with updated token
    func updating(_ token: BandwidthToken) -> BandwidthTokenCollection {
        var newTokens = tokens
        newTokens[token.id] = token
        return BandwidthTokenCollection(tokens: Array(newTokens.values))
    }
}

// MARK: - Convenience Extensions

extension BandwidthToken: CustomStringConvertible {
    var description: String {
        let usageInfo = lastReportedUsage.map { "usage: \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary))/s" } ?? "no usage data"
        return "BandwidthToken(id: \(id.uuidString.prefix(8)), download: \(downloadId.uuidString.prefix(8)), allocation: \(formattedBandwidth), priority: \(priority), \(usageInfo))"
    }
}

extension BandwidthToken: Identifiable {}

extension BandwidthToken: Equatable {
    static func == (lhs: BandwidthToken, rhs: BandwidthToken) -> Bool {
        return lhs.id == rhs.id
    }
}

extension BandwidthToken: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Factory Methods

extension BandwidthToken {
    /// Create a high-priority token for user-initiated downloads
    static func forUserDownload(
        downloadId: UUID,
        requestedBandwidth: Int64
    ) -> BandwidthToken {
        return BandwidthToken(
            downloadId: downloadId,
            allocatedBandwidth: requestedBandwidth,
            priority: .high,
            downloadType: .userInitiated,
            metadata: BandwidthTokenMetadata(
                purpose: "user-initiated download",
                tags: ["user", "high-priority"]
            )
        )
    }
    
    /// Create a low-priority token for background downloads
    static func forBackgroundDownload(
        downloadId: UUID,
        requestedBandwidth: Int64
    ) -> BandwidthToken {
        return BandwidthToken(
            downloadId: downloadId,
            allocatedBandwidth: requestedBandwidth,
            priority: .low,
            downloadType: .background,
            expirationTime: Date().addingTimeInterval(3600), // 1 hour expiration
            metadata: BandwidthTokenMetadata(
                purpose: "background download",
                tags: ["background", "low-priority"]
            )
        )
    }
    
    /// Create a critical token for system downloads
    static func forSystemDownload(
        downloadId: UUID,
        requestedBandwidth: Int64
    ) -> BandwidthToken {
        return BandwidthToken(
            downloadId: downloadId,
            allocatedBandwidth: requestedBandwidth,
            priority: .critical,
            downloadType: .system,
            metadata: BandwidthTokenMetadata(
                purpose: "system download",
                tags: ["system", "critical"]
            )
        )
    }
}