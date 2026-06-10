//
//  AnchorStore.swift
//  Exporter
//
//  每个指标的增量查询 anchor 持久化（UserDefaults + 安全归档）。
//

import Foundation
#if canImport(HealthKit)
import HealthKit

nonisolated struct AnchorStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for metric: HealthMetric) -> String { "anchor.\(metric.rawValue)" }

    func anchor(for metric: HealthMetric) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: key(for: metric)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func save(_ anchor: HKQueryAnchor, for metric: HealthMetric) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor,
                                                           requiringSecureCoding: true) else { return }
        saveArchivedAnchor(data, for: metric)
    }

    /// 保存已归档的 anchor 数据（用于延迟提交：查询时归档，确认后才落盘）。
    func saveArchivedAnchor(_ data: Data, for metric: HealthMetric) {
        defaults.set(data, forKey: key(for: metric))
    }

    /// 将 anchor 归档为 Data，便于跨任务边界传递（Sendable）。
    static func archive(_ anchor: HKQueryAnchor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    func reset(_ metric: HealthMetric) {
        defaults.removeObject(forKey: key(for: metric))
    }

    func resetAll() {
        HealthMetric.registered.forEach(reset)
    }
}
#endif
