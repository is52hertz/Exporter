//
//  HealthKitManager.swift
//  Exporter
//
//  HealthKit 授权与读取：增量（HKAnchoredObjectQuery）与日期段（HKSampleQuery）。
//

import Foundation
#if canImport(HealthKit)
import HealthKit

// MARK: - HealthMetric ↔ HealthKit 映射（仅在支持 HealthKit 的平台编译）

extension HealthMetric {
    /// 对应的 HealthKit 样本类型。
    var sampleType: HKSampleType {
        switch self {
        case .stepCount:          return HKQuantityType(.stepCount)
        case .activeEnergyBurned: return HKQuantityType(.activeEnergyBurned)
        case .heartRate:          return HKQuantityType(.heartRate)
        case .sleepAnalysis:      return HKCategoryType(.sleepAnalysis)
        }
    }

    /// 数值型样本读取所用单位；分类型为 nil。
    var hkUnit: HKUnit? {
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

    private let healthStore = HKHealthStore()
    private let anchorStore = AnchorStore()

    /// 是否已发起过授权请求（HealthKit 不暴露读权限的具体状态，仅记录是否请求过）。
    private(set) var hasRequestedAuthorization = false

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: 授权

    func requestAuthorization(for metrics: [HealthMetric]) async throws {
        guard isHealthDataAvailable else { throw HealthError.unavailable }
        let readTypes = Set(metrics.map { $0.sampleType as HKObjectType })
        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
        hasRequestedAuthorization = true
    }

    // MARK: 读取入口

    /// 按所选指标与模式读取并归一化样本。
    func fetch(metrics: [HealthMetric],
               mode: SyncMode,
               start: Date?,
               end: Date?) async throws -> [HealthSample] {
        guard isHealthDataAvailable else { throw HealthError.unavailable }
        var result: [HealthSample] = []
        for metric in metrics {
            switch mode {
            case .incremental:
                result += try await fetchIncremental(metric)
            case .range:
                result += try await fetchRange(metric, start: start, end: end)
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    // MARK: 增量查询

    private func fetchIncremental(_ metric: HealthMetric) async throws -> [HealthSample] {
        let storedAnchor = anchorStore.anchor(for: metric)
        let (samples, newAnchor): ([HKSample], HKQueryAnchor?) = try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: metric.sampleType,
                predicate: nil,
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
        if let newAnchor { anchorStore.save(newAnchor, for: metric) }
        return convert(samples, metric: metric)
    }

    // MARK: 日期段查询

    private func fetchRange(_ metric: HealthMetric, start: Date?, end: Date?) async throws -> [HealthSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: metric.sampleType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
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
        return convert(samples, metric: metric)
    }

    // MARK: 归一化

    private func convert(_ samples: [HKSample], metric: HealthMetric) -> [HealthSample] {
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
                    stringValue: Self.sleepStageName(c.value),
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
    private static func sleepStageName(_ rawValue: Int) -> String {
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
