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
    /// 允许范围与设置界面共用同一常量，避免加载端与控件分叉（R2）；
    /// 扩大范围（如 365 天）属产品决策，需同步修改此处与 SettingsView。
    static let largeExportThresholdRange = 1...30

    var largeExportThresholdDays: Int {
        didSet { defaults.set(largeExportThresholdDays, forKey: Keys.thresholdDays) }
    }

    /// 导出 JSON 是否包含每条样本的 HealthKit UUID（用于接收端精确去重；会显著增大文件，默认关）。
    var includeUUID: Bool {
        didSet { defaults.set(includeUUID, forKey: Keys.includeUUID) }
    }

    /// 是否已成功发起过一次授权请求。部分类型不出现在授权面板（地区/设备功能限制），
    /// 导致 getRequestStatusForAuthorization 永远返回 shouldRequest —— 用该标记兜底判定「已决」。
    var hasRequestedAuthorization: Bool {
        didSet { defaults.set(hasRequestedAuthorization, forKey: Keys.hasRequestedAuth) }
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
        // 夹紧到界面允许的 1...30：防御损坏 / 未来版本写入的越界存量值——
        // 0 或负数会让每次导出都弹确认、「仅最近 0 天」导出空范围；
        // 超大值则让「最近 N 天」超出用户在现有控件中能选出的范围（R2）。
        let storedThreshold = defaults.object(forKey: Keys.thresholdDays) as? Int
        self.largeExportThresholdDays = storedThreshold.map {
            min(max($0, Self.largeExportThresholdRange.lowerBound),
                Self.largeExportThresholdRange.upperBound)
        } ?? 3
        self.includeUUID = defaults.object(forKey: Keys.includeUUID) as? Bool ?? false
        self.hasRequestedAuthorization = defaults.bool(forKey: Keys.hasRequestedAuth)
    }

    private enum Keys {
        static let endpoint = "settings.endpoint"
        static let authHeader = "settings.authHeader"
        static let selectedMetrics = "settings.selectedMetrics"
        static let lastSyncDate = "settings.lastSyncDate"
        static let thresholdDays = "settings.thresholdDays"
        static let includeUUID = "settings.includeUUID"
        static let hasRequestedAuth = "settings.hasRequestedAuthorization"
    }
}
