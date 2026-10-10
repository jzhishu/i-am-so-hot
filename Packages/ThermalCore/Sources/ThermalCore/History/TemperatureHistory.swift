import Foundation

/// 温度历史（v0.5 历史记录，技术方案 §18）。
///
/// 三级降采样，内存常驻，全量约 300 个 bucket（< 20KB）：
/// - raw：每 tick 一点，保留最近 5 分钟
/// - tier2：30 秒/桶（由 raw 滚聚），保留最近 1 小时
/// - tier3：5 分钟/桶（由 tier2 滚聚），保留最近 24 小时
///
/// 持久化：tier2/tier3 可 Codable 导出，由 App 层低频批量写盘
/// （桶完成时才落盘，天然 batch，满足「Disk writes ≈ 0」预算）。
public struct TemperatureHistory: Sendable {

    /// 一个聚合桶：等时长窗口内的统计
    public struct Bucket: Codable, Sendable, Equatable {
        public let start: TimeInterval   // epoch 秒（桶起点）
        public let avg: Double
        public let min: Double
        public let max: Double
        public let count: Int            // 参与点数（跨层滚聚时加权用）

        public init(start: TimeInterval, avg: Double, min: Double, max: Double, count: Int) {
            self.start = start
            self.avg = avg
            self.min = min
            self.max = max
            self.count = count
        }

        /// 以桶为单位的加权合并（tier2 → tier3 滚聚用）
        func merged(with other: Bucket) -> Bucket {
            let total = count + other.count
            guard total > 0 else { return self }
            return Bucket(
                start: Swift.min(start, other.start),
                avg: (avg * Double(count) + other.avg * Double(other.count)) / Double(total),
                min: Swift.min(min, other.min),
                max: Swift.max(max, other.max),
                count: total
            )
        }
    }

    /// 一个窗口的汇总（UI 消费）
    public struct Summary: Sendable, Equatable {
        public let avg: Double
        public let min: Double
        public let max: Double
        /// 数据实际覆盖时长（秒）：冷启动初期窗口未铺满时供 UI 判断可信度
        public let coverage: TimeInterval
    }

    public static let rawWindow: TimeInterval = 5 * 60
    public static let tier2Interval: TimeInterval = 30
    public static let tier2Window: TimeInterval = 60 * 60
    public static let tier3Interval: TimeInterval = 5 * 60
    public static let tier3Window: TimeInterval = 24 * 60 * 60

    /// raw 点：(epoch 秒, 温度)
    private var raw: [(t: TimeInterval, v: Double)] = []
    private var tier2: [Bucket] = []
    private var tier3: [Bucket] = []

    /// 当前未闭合的 tier2 桶起点（nil = 尚未开始）
    private var openTier2Start: TimeInterval?
    /// 当前未闭合的 tier3 桶起点
    private var openTier3Start: TimeInterval?

    public init() {}

    // MARK: - 记录

    /// 每 tick 记录一次温度。调用方保证 at 单调递增（timer tick 天然满足）。
    public mutating func record(_ celsius: Double, at now: Date) {
        let t = now.timeIntervalSince1970
        raw.append((t, celsius))

        // raw 剪枝（5 分钟窗口）
        raw.removeAll { $0.t < t - Self.rawWindow }

        // tier2 闭桶：进入新 30s 桶时，把已过去的桶从 raw 滚聚出来
        let bucket2 = Self.bucketStart(t, interval: Self.tier2Interval)
        if openTier2Start == nil { openTier2Start = bucket2 }
        while let open = openTier2Start, open < bucket2 {
            closeTier2Bucket(open)
            openTier2Start = open + Self.tier2Interval
        }

        // 三层剪枝
        tier2.removeAll { $0.start < t - Self.tier2Window }
        tier3.removeAll { $0.start < t - Self.tier3Window }
    }

    /// 闭合一个 tier2 桶：聚合该窗口内的 raw 点，并尝试滚聚 tier3
    private mutating func closeTier2Bucket(_ start: TimeInterval) {
        let points = raw.filter { $0.t >= start && $0.t < start + Self.tier2Interval }
        guard !points.isEmpty else { return }
        let values = points.map(\.v)
        let bucket = Bucket(
            start: start,
            avg: values.reduce(0, +) / Double(values.count),
            min: values.min()!,
            max: values.max()!,
            count: values.count
        )
        tier2.append(bucket)

        // tier3 滚聚：tier2 桶落入哪个 5 分钟桶
        let bucket3 = Self.bucketStart(start, interval: Self.tier3Interval)
        if openTier3Start == nil { openTier3Start = bucket3 }
        if bucket3 == openTier3Start {
            // 与未闭合的 tier3 桶合并（暂存在 tier3 末尾）
            if let last = tier3.last, last.start == bucket3 {
                tier3[tier3.count - 1] = last.merged(with: bucket)
            } else {
                tier3.append(bucket)
            }
        } else {
            // 跨入新 tier3 桶：旧桶已在数组里（闭合语义由剪枝保证），开新桶
            openTier3Start = bucket3
            tier3.append(bucket)
        }
    }

    private static func bucketStart(_ t: TimeInterval, interval: TimeInterval) -> TimeInterval {
        (t / interval).rounded(.down) * interval
    }

    // MARK: - 查询

    /// 最近 5 分钟（raw 层）
    public func last5Minutes(now: Date = Date()) -> Summary? {
        summarizeRaw(now: now)
    }

    /// 最近 1 小时（tier2 层）
    public func lastHour(now: Date = Date()) -> Summary? {
        summarize(tier2, window: Self.tier2Window, now: now)
    }

    /// 最近 24 小时（tier3 层）
    public func last24Hours(now: Date = Date()) -> Summary? {
        summarize(tier3, window: Self.tier3Window, now: now)
    }

    private func summarizeRaw(now: Date) -> Summary? {
        let cutoff = now.timeIntervalSince1970 - Self.rawWindow
        let values = raw.filter { $0.t >= cutoff }.map(\.v)
        guard values.count >= 2 else { return nil }
        return Summary(
            avg: values.reduce(0, +) / Double(values.count),
            min: values.min()!,
            max: values.max()!,
            coverage: Self.rawWindow
        )
    }

    private func summarize(_ buckets: [Bucket], window: TimeInterval, now: Date) -> Summary? {
        let cutoff = now.timeIntervalSince1970 - window
        let windowBuckets = buckets.filter { $0.start >= cutoff }
        guard let first = windowBuckets.first, windowBuckets.count >= 2 else { return nil }
        let merged = windowBuckets.dropFirst().reduce(first) { $0.merged(with: $1) }
        return Summary(
            avg: merged.avg,
            min: merged.min,
            max: merged.max,
            coverage: min(now.timeIntervalSince1970 - first.start, window)
        )
    }

    // MARK: - 持久化（App 层低频批量写盘）

    /// 可持久化快照（只存聚合层；raw 重建成本仅 5 分钟，不存）
    public struct Persisted: Codable, Sendable {
        public var tier2: [Bucket]
        public var tier3: [Bucket]
        public var openTier2Start: TimeInterval?
        public var openTier3Start: TimeInterval?
    }

    public func export() -> Persisted {
        Persisted(
            tier2: tier2, tier3: tier3,
            openTier2Start: openTier2Start, openTier3Start: openTier3Start
        )
    }

    /// 从持久化恢复。过期数据按当前时间剪枝。
    public init(restoring persisted: Persisted, now: Date = Date()) {
        self.init()
        let t = now.timeIntervalSince1970
        self.tier2 = persisted.tier2.filter { $0.start >= t - Self.tier2Window }
        self.tier3 = persisted.tier3.filter { $0.start >= t - Self.tier3Window }
        self.openTier2Start = persisted.openTier2Start
        self.openTier3Start = persisted.openTier3Start
    }
}
