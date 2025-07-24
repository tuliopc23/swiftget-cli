import Foundation
import Logging

/// Intelligent bandwidth allocation across multiple download segments
actor BandwidthAllocator {
    private let logger: Logger
    private let totalBandwidthLimit: Int? // bytes per second
    private var segmentAllocations: [Int: SegmentAllocation] = [:]
    private var globalStats: GlobalBandwidthStats = GlobalBandwidthStats()
    
    struct SegmentAllocation {
        let segmentIndex: Int
        var allocatedBandwidth: Int // bytes per second
        var actualThroughput: Double // bytes per second
        var efficiency: Double // actual / allocated
        var lastUpdate: Date
        var isActive: Bool
        
        var efficiencyRatio: Double {
            guard allocatedBandwidth > 0 else { return 0 }
            return actualThroughput / Double(allocatedBandwidth)
        }
        
        var isUnderperforming: Bool {
            return efficiencyRatio < 0.7 // Using less than 70% of allocated bandwidth
        }
        
        var isOverperforming: Bool {
            return efficiencyRatio > 1.2 // Using more than 120% of allocated bandwidth
        }
    }
    
    struct GlobalBandwidthStats {
        var totalAllocated: Int = 0
        var totalActual: Double = 0
        var activeSegments: Int = 0
        var reallocationCount: Int = 0
        var lastReallocation: Date = Date()
        
        var overallEfficiency: Double {
            guard totalAllocated > 0 else { return 0 }
            return totalActual / Double(totalAllocated)
        }
        
        var formattedStats: String {
            return """
            Bandwidth Allocation Stats:
              Total Allocated: \(formatBandwidth(totalAllocated))
              Total Actual: \(formatBandwidth(Int(totalActual)))
              Active Segments: \(activeSegments)
              Overall Efficiency: \(String(format: "%.1f", overallEfficiency * 100))%
              Reallocations: \(reallocationCount)
            """
        }
    }
    
    init(totalBandwidthLimit: Int? = nil, logger: Logger) {
        self.totalBandwidthLimit = totalBandwidthLimit
        self.logger = logger
    }
    
    /// Register a new segment for bandwidth allocation
    func registerSegment(_ segmentIndex: Int, estimatedSize: Int64) {
        let initialAllocation = calculateInitialAllocation(for: segmentIndex, estimatedSize: estimatedSize)
        
        segmentAllocations[segmentIndex] = SegmentAllocation(
            segmentIndex: segmentIndex,
            allocatedBandwidth: initialAllocation,
            actualThroughput: 0,
            efficiency: 1.0,
            lastUpdate: Date(),
            isActive: true
        )
        
        updateGlobalStats()
        
        logger.debug("Registered segment \(segmentIndex) with \(formatBandwidth(initialAllocation)) allocation")
    }
    
    /// Update actual throughput for a segment
    func updateSegmentThroughput(_ segmentIndex: Int, bytesTransferred: Int, timeInterval: TimeInterval) {
        guard var allocation = segmentAllocations[segmentIndex] else { return }
        
        let throughput = Double(bytesTransferred) / timeInterval
        allocation.actualThroughput = throughput
        allocation.efficiency = allocation.efficiencyRatio
        allocation.lastUpdate = Date()
        
        segmentAllocations[segmentIndex] = allocation
        
        // Trigger reallocation if needed
        if shouldReallocate() {
            reallocateBandwidth()
        }
        
        updateGlobalStats()
    }
    
    /// Mark a segment as completed
    func completeSegment(_ segmentIndex: Int) {
        guard var allocation = segmentAllocations[segmentIndex] else { return }
        
        allocation.isActive = false
        segmentAllocations[segmentIndex] = allocation
        
        logger.debug("Completed segment \(segmentIndex), final efficiency: \(String(format: "%.1f", allocation.efficiency * 100))%")
        
        // Redistribute bandwidth from completed segment
        redistributeFromCompletedSegment(segmentIndex)
        updateGlobalStats()
    }
    
    /// Get current bandwidth allocation for a segment
    func getAllocation(for segmentIndex: Int) -> Int {
        return segmentAllocations[segmentIndex]?.allocatedBandwidth ?? 0
    }
    
    /// Get current bandwidth statistics
    func getStats() -> GlobalBandwidthStats {
        updateGlobalStats()
        return globalStats
    }
    
    /// Force reallocation of bandwidth
    func forceReallocation() {
        reallocateBandwidth()
    }
    
    // MARK: - Private Methods
    
    private func calculateInitialAllocation(for segmentIndex: Int, estimatedSize: Int64) -> Int {
        let activeSegmentCount = segmentAllocations.values.filter { $0.isActive }.count + 1
        
        if let totalLimit = totalBandwidthLimit {
            // Distribute total bandwidth evenly among active segments
            return totalLimit / activeSegmentCount
        } else {
            // No global limit, use heuristic based on estimated size
            let baseAllocation = 1024 * 1024 // 1 MB/s base
            let sizeMultiplier = min(10.0, Double(estimatedSize) / (10 * 1024 * 1024)) // Scale up to 10x for large files
            return Int(Double(baseAllocation) * sizeMultiplier)
        }
    }
    
    private func shouldReallocate() -> Bool {
        let timeSinceLastReallocation = Date().timeIntervalSince(globalStats.lastReallocation)
        
        // Don't reallocate too frequently
        guard timeSinceLastReallocation > 5.0 else { return false }
        
        let activeAllocations = segmentAllocations.values.filter { $0.isActive }
        
        // Reallocate if we have significant efficiency imbalances
        let underperformingCount = activeAllocations.filter { $0.isUnderperforming }.count
        let overperformingCount = activeAllocations.filter { $0.isOverperforming }.count
        
        return underperformingCount > 0 && overperformingCount > 0
    }
    
    private func reallocateBandwidth() {
        let activeAllocations = segmentAllocations.values.filter { $0.isActive }
        guard activeAllocations.count > 1 else { return }
        
        logger.debug("Reallocating bandwidth across \(activeAllocations.count) segments")
        
        // Calculate total available bandwidth
        let totalAvailable = totalBandwidthLimit ?? activeAllocations.map { $0.allocatedBandwidth }.reduce(0, +)
        
        // Sort segments by efficiency
        let sortedSegments = activeAllocations.sorted { $0.efficiency > $1.efficiency }
        
        // Reallocate based on performance
        var newAllocations: [Int: Int] = [:]
        var remainingBandwidth = totalAvailable
        
        // Give high-performing segments more bandwidth
        for (index, allocation) in sortedSegments.enumerated() {
            let segmentIndex = allocation.segmentIndex
            let performanceWeight = calculatePerformanceWeight(allocation, rank: index, totalSegments: sortedSegments.count)
            let newAllocation = min(remainingBandwidth, Int(Double(totalAvailable) * performanceWeight))
            
            newAllocations[segmentIndex] = max(64 * 1024, newAllocation) // Minimum 64KB/s
            remainingBandwidth -= newAllocation
        }
        
        // Apply new allocations
        for (segmentIndex, newAllocation) in newAllocations {
            if var allocation = segmentAllocations[segmentIndex] {
                let oldAllocation = allocation.allocatedBandwidth
                allocation.allocatedBandwidth = newAllocation
                segmentAllocations[segmentIndex] = allocation
                
                logger.debug("Segment \(segmentIndex): \(formatBandwidth(oldAllocation)) → \(formatBandwidth(newAllocation))")
            }
        }
        
        globalStats.reallocationCount += 1
        globalStats.lastReallocation = Date()
    }
    
    private func calculatePerformanceWeight(_ allocation: SegmentAllocation, rank: Int, totalSegments: Int) -> Double {
        // Base weight distribution: better performers get more bandwidth
        let baseWeight = 1.0 / Double(totalSegments)
        let rankBonus = (Double(totalSegments - rank) / Double(totalSegments)) * 0.5
        let efficiencyBonus = min(0.3, allocation.efficiency * 0.3)
        
        return baseWeight + rankBonus + efficiencyBonus
    }
    
    private func redistributeFromCompletedSegment(_ completedSegmentIndex: Int) {
        guard let completedAllocation = segmentAllocations[completedSegmentIndex] else { return }
        
        let activeSegments = segmentAllocations.values.filter { $0.isActive && $0.segmentIndex != completedSegmentIndex }
        guard !activeSegments.isEmpty else { return }
        
        let bandwidthToRedistribute = completedAllocation.allocatedBandwidth
        let bonusPerSegment = bandwidthToRedistribute / activeSegments.count
        
        for activeSegment in activeSegments {
            if var allocation = segmentAllocations[activeSegment.segmentIndex] {
                allocation.allocatedBandwidth += bonusPerSegment
                segmentAllocations[activeSegment.segmentIndex] = allocation
                
                logger.debug("Redistributed \(formatBandwidth(bonusPerSegment)) to segment \(activeSegment.segmentIndex)")
            }
        }
    }
    
    private func updateGlobalStats() {
        let activeAllocations = segmentAllocations.values.filter { $0.isActive }
        
        globalStats.totalAllocated = activeAllocations.map { $0.allocatedBandwidth }.reduce(0, +)
        globalStats.totalActual = activeAllocations.map { $0.actualThroughput }.reduce(0, +)
        globalStats.activeSegments = activeAllocations.count
    }
    
    /// Clean up old segment data
    func cleanup() {
        let cutoffTime = Date().addingTimeInterval(-3600) // Keep last hour
        segmentAllocations = segmentAllocations.filter { $0.value.lastUpdate > cutoffTime || $0.value.isActive }
    }
}

// MARK: - Utility Functions

private func formatBandwidth(_ bytesPerSecond: Int) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var size = Double(bytesPerSecond)
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

/// Bandwidth-aware speed limiter that respects allocations
class BandwidthAwareSpeedLimiter {
    private let allocator: BandwidthAllocator
    private let segmentIndex: Int
    private var windowStart: Date
    private var bytesInWindow: Int
    
    init(allocator: BandwidthAllocator, segmentIndex: Int) {
        self.allocator = allocator
        self.segmentIndex = segmentIndex
        self.windowStart = Date()
        self.bytesInWindow = 0
    }
    
    func throttle(wrote bytes: Int) async {
        bytesInWindow += bytes
        let elapsed = Date().timeIntervalSince(windowStart)
        
        // Get current allocation
        let maxBytesPerSecond = await allocator.getAllocation(for: segmentIndex)
        
        if elapsed < 1.0 && bytesInWindow > maxBytesPerSecond {
            let sleepTime = 1.0 - elapsed
            if sleepTime > 0 {
                let ns = UInt64(sleepTime * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
            
            // Update throughput stats
            await allocator.updateSegmentThroughput(segmentIndex, bytesTransferred: bytesInWindow, timeInterval: elapsed)
            
            windowStart = Date()
            bytesInWindow = 0
        } else if elapsed >= 1.0 {
            // Update throughput stats
            await allocator.updateSegmentThroughput(segmentIndex, bytesTransferred: bytesInWindow, timeInterval: elapsed)
            
            windowStart = Date()
            bytesInWindow = 0
        }
    }
}

