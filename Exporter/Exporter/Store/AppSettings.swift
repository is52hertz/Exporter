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

    /// 设置页编辑值的副本；地址校验时去掉首尾空白，持久化时保留原始输入。
    nonisolated struct EndpointDraft: Equatable, Sendable {
        var endpoint: String
        var backupEndpoint: String
        var authorizationHeader: String

        var trimmedEndpoint: String { endpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
        var trimmedBackupEndpoint: String { backupEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
        var hasValidPrimaryEndpoint: Bool { HTTPSender.validatedURL(trimmedEndpoint) != nil }
        var validatedBackupURL: URL? { HTTPSender.validatedBackupURL(trimmedBackupEndpoint) }

        var isValid: Bool {
            let hasPrimary = !trimmedEndpoint.isEmpty
            guard !hasPrimary || hasValidPrimaryEndpoint else { return false }
            return trimmedBackupEndpoint.isEmpty || (hasPrimary && validatedBackupURL != nil)
        }
    }

    /// 三个字段共用一个观察及持久化快照，编辑副本不会通知发送方。
    private(set) var endpointDraft: EndpointDraft {
        didSet { Self.persistEndpointDraft(endpointDraft, in: defaults) }
    }

    @discardableResult
    func applyEndpointDraft(_ draft: EndpointDraft) -> Bool {
        guard draft.isValid else { return false }
        if draft != endpointDraft { endpointDraft = draft }
        return true
    }

    func canEnableBackgroundPush(with draft: EndpointDraft) -> Bool {
        draft == endpointDraft && draft.hasValidPrimaryEndpoint && draft.isValid
    }

    func setBackgroundPushEnabled(_ enabled: Bool, with draft: EndpointDraft) {
        // 关闭立即生效；开启只允许使用未被草稿改动的有效已保存配置。
        guard !enabled || canEnableBackgroundPush(with: draft) else { return }
        backgroundPushEnabled = enabled
    }

    // 兼容既有读写方；设置页通过 applyEndpointDraft 一次替换整组配置。
    var endpoint: String {
        get { endpointDraft.endpoint }
        set { endpointDraft.endpoint = newValue }
    }

    var backupEndpoint: String {
        get { endpointDraft.backupEndpoint }
        set { endpointDraft.backupEndpoint = newValue }
    }

    /// 最近一次服务器确认成功的地址，只保存主机名，不保存路径、查询参数或凭据。
    var lastSendReceipt: SendReceipt? {
        didSet {
            let stored = lastSendReceipt.flatMap { try? JSONEncoder().encode($0) }
            defaults.set(stored, forKey: Keys.lastSendReceipt)
        }
    }

    /// 可选 Authorization 头的值，如 "Bearer xxx"。
    var authorizationHeader: String {
        get { endpointDraft.authorizationHeader }
        set { endpointDraft.authorizationHeader = newValue }
    }

    var backgroundPushEnabled: Bool {
        didSet { defaults.set(backgroundPushEnabled, forKey: Keys.backgroundPushEnabled) }
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
        self.endpointDraft = Self.loadEndpointDraft(from: defaults)
        self.lastSendReceipt = defaults.data(forKey: Keys.lastSendReceipt).flatMap {
            try? JSONDecoder().decode(SendReceipt.self, from: $0)
        }
        self.backgroundPushEnabled = defaults.bool(forKey: Keys.backgroundPushEnabled)

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

    private static func loadEndpointDraft(from defaults: UserDefaults) -> EndpointDraft {
        if let stored = defaults.dictionary(forKey: Keys.endpointConfiguration),
           let endpoint = stored[Keys.endpoint] as? String,
           let backup = stored[Keys.backupEndpoint] as? String,
           let header = stored[Keys.authHeader] as? String {
            return EndpointDraft(endpoint: endpoint, backupEndpoint: backup, authorizationHeader: header)
        }

        let endpoint = defaults.string(forKey: Keys.endpoint)
        let backup = defaults.string(forKey: Keys.backupEndpoint)
        let header = defaults.string(forKey: Keys.authHeader)
        let migrated = EndpointDraft(endpoint: endpoint ?? "", backupEndpoint: backup ?? "", authorizationHeader: header ?? "")
        if endpoint != nil || backup != nil || header != nil {
            // 先写完整快照再清理旧键，避免留下旧的 Authorization 值。
            persistEndpointDraft(migrated, in: defaults)
            for key in [Keys.endpoint, Keys.backupEndpoint, Keys.authHeader] {
                defaults.removeObject(forKey: key)
            }
        }
        return migrated
    }

    private static func persistEndpointDraft(_ draft: EndpointDraft, in defaults: UserDefaults) {
        defaults.set([Keys.endpoint: draft.endpoint, Keys.backupEndpoint: draft.backupEndpoint,
                      Keys.authHeader: draft.authorizationHeader], forKey: Keys.endpointConfiguration)
    }

    private enum Keys {
        static let endpointConfiguration = "settings.endpointConfiguration"
        static let endpoint = "settings.endpoint"
        static let backupEndpoint = "settings.backupEndpoint"
        static let lastSendReceipt = "settings.lastSendReceipt"
        static let authHeader = "settings.authHeader"
        static let backgroundPushEnabled = "settings.backgroundPushEnabled"
        static let selectedMetrics = "settings.selectedMetrics"
        static let lastSyncDate = "settings.lastSyncDate"
        static let thresholdDays = "settings.thresholdDays"
        static let includeUUID = "settings.includeUUID"
        static let hasRequestedAuth = "settings.hasRequestedAuthorization"
    }
}
