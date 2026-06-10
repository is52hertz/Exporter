//
//  AppSettings.swift
//  Exporter
//
//  用户可配置项：API endpoint、可选鉴权 header、同步模式、所选指标与日期段。
//  endpoint / header / 所选指标持久化到 UserDefaults。
//

import Foundation

@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// 远程 API endpoint（留空则只走本地预览 / 分享）。
    var endpoint: String {
        didSet { defaults.set(endpoint, forKey: Keys.endpoint) }
    }

    /// 可选 Authorization 头的值，如 "Bearer xxx"。
    var authorizationHeader: String {
        didSet { defaults.set(authorizationHeader, forKey: Keys.authHeader) }
    }

    /// 当前选中的指标集合。
    var selectedMetrics: Set<HealthMetric> {
        didSet {
            defaults.set(selectedMetrics.map(\.rawValue), forKey: Keys.selectedMetrics)
        }
    }

    /// 同步模式（不持久化，默认增量）。
    var mode: SyncMode = .incremental

    /// 日期段模式下的起止（默认最近 7 天）。
    var rangeStart: Date
    var rangeEnd: Date

    /// 上次成功的全量增量同步时间（仅全量增量更新；局部读取不更新）。
    var lastSyncDate: Date? {
        didSet { defaults.set(lastSyncDate, forKey: Keys.lastSyncDate) }
    }

    /// 导出跨度超过该天数时弹确认（默认 3 天）。
    var largeExportThresholdDays: Int {
        didSet { defaults.set(largeExportThresholdDays, forKey: Keys.thresholdDays) }
    }

    var hasEndpoint: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.endpoint = defaults.string(forKey: Keys.endpoint) ?? ""
        self.authorizationHeader = defaults.string(forKey: Keys.authHeader) ?? ""

        if let raw = defaults.array(forKey: Keys.selectedMetrics) as? [String] {
            self.selectedMetrics = Set(raw.compactMap(HealthMetric.init(rawValue:)))
        } else {
            self.selectedMetrics = Set(HealthMetric.registered)
        }

        let now = Date()
        self.rangeEnd = now
        self.rangeStart = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now

        self.lastSyncDate = defaults.object(forKey: Keys.lastSyncDate) as? Date
        let storedThreshold = defaults.object(forKey: Keys.thresholdDays) as? Int
        self.largeExportThresholdDays = storedThreshold ?? 3
    }

    private enum Keys {
        static let endpoint = "settings.endpoint"
        static let authHeader = "settings.authHeader"
        static let selectedMetrics = "settings.selectedMetrics"
        static let lastSyncDate = "settings.lastSyncDate"
        static let thresholdDays = "settings.thresholdDays"
    }
}
