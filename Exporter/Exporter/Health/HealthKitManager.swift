//
//  HealthKitManager.swift
//  Exporter
//
//  HealthKit 授权与读取：增量（HKAnchoredObjectQuery）与日期段（HKSampleQuery）。
//  查询/归一化为 nonisolated，跑在后台线程，避免阻塞主线程。
//

import Foundation
#if canImport(HealthKit)
import HealthKit

// MARK: - HealthMetric ↔ HealthKit 映射（仅在支持 HealthKit 的平台编译）

extension HealthMetric {
    /// 对应的 HealthKit 样本类型。
    nonisolated var sampleType: HKSampleType {
        switch self {
        case .stepCount:          return HKQuantityType(.stepCount)
        case .activeEnergyBurned: return HKQuantityType(.activeEnergyBurned)
        case .heartRate:          return HKQuantityType(.heartRate)
        case .sleepAnalysis:      return HKCategoryType(.sleepAnalysis)
        }
    }

    /// 数值型样本读取所用单位；分类型为 nil。
    nonisolated var hkUnit: HKUnit? {
        switch self {
        case .stepCount:          return .count()
        case .activeEnergyBurned: return .kilocalorie()
        case .heartRate:          return HKUnit.count().unitDivided(by: .minute())
        case .sleepAnalysis:      return nil
        }
    }
}

// MARK: - Manager

@MainActor
@Observable
final class HealthKitManager {
    enum HealthError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: return "此设备不支持 HealthKit。"
            }
        }
    }

    // 二者均为 Sendable / 线程安全，标 nonisolated 以便后台线程的查询方法访问。
    private nonisolated let healthStore = HKHealthStore()
    private nonisolated let anchorStore = AnchorStore()

    /// 是否已发起过授权请求（HealthKit 不暴露读权限的具体状态，仅记录是否请求过）。
    private(set) var hasRequestedAuthorization = false

    nonisolated var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: 授权

    func requestAuthorization(for metrics: [HealthMetric]) async throws {
        guard isHealthDataAvailable else { throw HealthError.unavailable }
        let readTypes = Set(metrics.map { $0.sampleType as HKObjectType })
        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
        hasRequestedAuthorization = true
    }

    /// 系统是否还会为这些类型弹出授权面板。`.unnecessary` 表示已决，无法再弹。
    nonisolated func authorizationRequestStatus(for metrics: [HealthMetric]) async -> HKAuthorizationRequestStatus {
        guard isHealthDataAvailable else { return .unknown }
        let readTypes = Set(metrics.map { $0.sampleType as HKObjectType })
        return await withCheckedContinuation { continuation in
            healthStore.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, _ in
                continuation.resume(returning: status)
            }
        }
    }

    /// 授权是否已决（系统不会再弹面板）。已决后只能引导用户去系统设置 / 健康 App 修改。
    nonisolated func isAuthorizationDetermined(for metrics: [HealthMetric]) async -> Bool {
        await authorizationRequestStatus(for: metrics) == .unnecessary
    }

    /// 轻量探测：返回该指标最近一条样本的时间（读到=有数据/已授权；nil=无数据或未授权）。
    nonisolated func probeLatest(_ metric: HealthMetric) async -> Date? {
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let samples = try? await runSampleQuery(metric.sampleType, predicate: nil, limit: 1, sort: sort)
        return samples?.first?.endDate
    }

    // MARK: 读取入口

    /// 读取结果。增量模式携带待提交的 anchor（归档为 Data，Sendable），
    /// 由调用方在用户确认后 `commit(_:)`，避免估算/取消时误推进 anchor。
    nonisolated struct FetchOutcome: Sendable {
        let samples: [HealthSample]
        let pendingAnchors: [PendingAnchor]
        let isIncremental: Bool

        struct PendingAnchor: Sendable {
            let metric: HealthMetric
            let anchorData: Data
        }
    }

    /// 按所选指标与模式并行读取并归一化样本。
    /// - Parameter maxLookback: 可选回溯上限（活口）；设置后只读取 now-maxLookback 之后的数据。
    nonisolated func fetch(metrics: [HealthMetric],
                           mode: SyncMode,
                           start: Date?,
                           end: Date?,
                           maxLookback: TimeInterval? = nil) async throws -> FetchOutcome {
        guard isHealthDataAvailable else { throw HealthError.unavailable }
        return try await withThrowingTaskGroup(
            of: (samples: [HealthSample], anchor: FetchOutcome.PendingAnchor?).self
        ) { group in
            for metric in metrics {
                group.addTask {
                    switch mode {
                    case .incremental:
                        let (samples, anchorData) = try await self.fetchIncremental(metric, maxLookback: maxLookback)
                        let pending = anchorData.map { FetchOutcome.PendingAnchor(metric: metric, anchorData: $0) }
                        return (samples, pending)
                    case .range:
                        let samples = try await self.fetchRange(metric, start: start, end: end, maxLookback: maxLookback)
                        return (samples, nil)
                    }
                }
            }
            var all: [HealthSample] = []
            var anchors: [FetchOutcome.PendingAnchor] = []
            for try await part in group {
                all += part.samples
                if let anchor = part.anchor { anchors.append(anchor) }
            }
            return FetchOutcome(samples: all.sorted { $0.start < $1.start },
                                pendingAnchors: anchors,
                                isIncremental: mode == .incremental)
        }
    }

    /// 提交一次增量读取的 anchor（仅在用户确认导出后调用）。
    func commit(_ outcome: FetchOutcome) {
        for pending in outcome.pendingAnchors {
            anchorStore.saveArchivedAnchor(pending.anchorData, for: pending.metric)
        }
    }

    // MARK: 增量查询

    /// 返回归一化样本与新 anchor（归档为 Data），**不**落盘 anchor。
    private nonisolated func fetchIncremental(_ metric: HealthMetric,
                                              maxLookback: TimeInterval?) async throws -> ([HealthSample], Data?) {
        let storedAnchor = anchorStore.anchor(for: metric)
        let predicate = Self.lookbackPredicate(maxLookback)
        let (samples, newAnchor): ([HKSample], HKQueryAnchor?) = try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: metric.sampleType,
                predicate: predicate,
                anchor: storedAnchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples ?? [], newAnchor))
                }
            }
            healthStore.execute(query)
        }
        let anchorData = newAnchor.flatMap { AnchorStore.archive($0) }
        return (Self.convert(samples, metric: metric), anchorData)
    }

    // MARK: 日期段查询

    private nonisolated func fetchRange(_ metric: HealthMetric,
                                        start: Date?,
                                        end: Date?,
                                        maxLookback: TimeInterval?) async throws -> [HealthSample] {
        var effectiveStart = start
        if let maxLookback {
            let floor = Date().addingTimeInterval(-maxLookback)
            effectiveStart = max(start ?? floor, floor)
        }
        let predicate = HKQuery.predicateForSamples(withStart: effectiveStart, end: end, options: [.strictStartDate])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples = try await runSampleQuery(metric.sampleType, predicate: predicate,
                                               limit: HKObjectQueryNoLimit, sort: sort)
        return Self.convert(samples, metric: metric)
    }

    /// 通用样本查询封装。
    private nonisolated func runSampleQuery(_ type: HKSampleType,
                                            predicate: NSPredicate?,
                                            limit: Int,
                                            sort: [NSSortDescriptor]) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    private nonisolated static func lookbackPredicate(_ maxLookback: TimeInterval?) -> NSPredicate? {
        guard let maxLookback else { return nil }
        let start = Date().addingTimeInterval(-maxLookback)
        return HKQuery.predicateForSamples(withStart: start, end: nil, options: [.strictStartDate])
    }

    // MARK: 归一化

    private nonisolated static func convert(_ samples: [HKSample], metric: HealthMetric) -> [HealthSample] {
        samples.compactMap { sample in
            let source = sample.sourceRevision.source.name
            switch metric.kind {
            case .quantity:
                guard let q = sample as? HKQuantitySample, let unit = metric.hkUnit else { return nil }
                return HealthSample(
                    type: metric.rawValue,
                    category: metric.category.rawValue,
                    value: q.quantity.doubleValue(for: unit),
                    stringValue: nil,
                    unit: metric.unitString,
                    start: q.startDate,
                    end: q.endDate,
                    source: source,
                    uuid: q.uuid.uuidString
                )
            case .category:
                guard let c = sample as? HKCategorySample else { return nil }
                return HealthSample(
                    type: metric.rawValue,
                    category: metric.category.rawValue,
                    value: nil,
                    stringValue: sleepStageName(c.value),
                    unit: nil,
                    start: c.startDate,
                    end: c.endDate,
                    source: source,
                    uuid: c.uuid.uuidString
                )
            }
        }
    }

    /// 将 HKCategoryValueSleepAnalysis 原始值映射为可读字符串。
    private nonisolated static func sleepStageName(_ rawValue: Int) -> String {
        guard let stage = HKCategoryValueSleepAnalysis(rawValue: rawValue) else { return "unknown" }
        switch stage {
        case .inBed:             return "inBed"
        case .asleepUnspecified: return "asleepUnspecified"
        case .awake:             return "awake"
        case .asleepCore:        return "asleepCore"
        case .asleepDeep:        return "asleepDeep"
        case .asleepREM:         return "asleepREM"
        @unknown default:        return "unknown"
        }
    }
}
#endif
