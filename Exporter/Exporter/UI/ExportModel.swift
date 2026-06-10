//
//  ExportModel.swift
//  Exporter
//
//  UI 协调层：授权、探测、读取、JSON 生成与发送。
//  重活（查询/编码）经由 HealthKitManager 的 nonisolated 方法与 Task.detached 移出主线程，
//  所有 @Observable 状态更新仍在主线程，避免数据竞争与界面冻结。
//

import Foundation
import UIKit

@MainActor
@Observable
final class ExportModel {
    let settings: AppSettings
    let health: HealthKitManager

    var samples: [HealthSample] = []
    var jsonString: String = ""
    var isWorking = false
    var statusMessage: String?
    var errorMessage: String?
    var showPreview = false

    // 授权
    var authorizationDetermined = false
    var showAuthSettingsAlert = false

    // 各指标最近样本时间（保守探测：有=已授权且有数据；无=未授权或无数据）
    var probeDates: [HealthMetric: Date] = [:]
    var hasProbed = false

    // 大导出确认弹层（非 nil 即显示）
    var confirm: LargeExportConfirm?

    private var fetchTask: Task<Void, Never>?
    private var pendingOutcome: HealthKitManager.FetchOutcome?

    /// 大导出确认状态。estimatedCount 为 nil 表示仍在估算。
    struct LargeExportConfirm {
        let spanText: String
        var estimatedCount: Int?
        let recentDays: Int
    }

    init() {
        self.settings = AppSettings()
        self.health = HealthKitManager()
    }

    init(settings: AppSettings, health: HealthKitManager) {
        self.settings = settings
        self.health = health
    }

    var canRead: Bool { !settings.selectedMetrics.isEmpty }

    private var selectedMetricsInOrder: [HealthMetric] {
        HealthMetric.registered.filter { settings.selectedMetrics.contains($0) }
    }

    // MARK: 授权

    func refreshAuthorizationState() async {
        authorizationDetermined = await health.isAuthorizationDetermined(for: HealthMetric.registered)
    }

    /// 未决 → 弹系统授权面板；已决 → 弹说明（引导去设置）。
    func handleAuthorizationTap() async {
        if authorizationDetermined {
            showAuthSettingsAlert = true
            return
        }
        errorMessage = nil
        do {
            try await health.requestAuthorization(for: HealthMetric.registered)
            statusMessage = "已发起授权请求。"
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshAuthorizationState()
        await refreshProbes()
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: 探测

    func refreshProbes() async {
        let metrics = HealthMetric.registered
        let results = await withTaskGroup(of: (HealthMetric, Date?).self) { group -> [(HealthMetric, Date?)] in
            for metric in metrics {
                group.addTask { (metric, await self.health.probeLatest(metric)) }
            }
            var acc: [(HealthMetric, Date?)] = []
            for await pair in group { acc.append(pair) }
            return acc
        }
        var dict: [HealthMetric: Date] = [:]
        for (metric, date) in results where date != nil { dict[metric] = date }
        probeDates = dict
        hasProbed = true
    }

    // MARK: 导出入口

    func startExport() {
        guard canRead else {
            errorMessage = "请至少选择一个指标。"
            return
        }
        errorMessage = nil
        let threshold = TimeInterval(settings.largeExportThresholdDays) * 86_400
        let span = exportSpanSeconds()           // nil = 全部历史
        let exceeds = (span == nil) || (span! > threshold)
        if exceeds {
            presentConfirm()
        } else {
            runExport(mode: settings.mode, start: rangeStartIfNeeded, end: rangeEndIfNeeded,
                      isFullIncremental: settings.mode == .incremental)
        }
    }

    private var rangeStartIfNeeded: Date? { settings.mode == .range ? settings.rangeStart : nil }
    private var rangeEndIfNeeded: Date? { settings.mode == .range ? settings.rangeEnd : nil }

    /// 估算导出跨度（秒）；nil 表示“全部历史”（无上界）。
    private func exportSpanSeconds() -> TimeInterval? {
        switch settings.mode {
        case .range:
            return settings.rangeEnd.timeIntervalSince(settings.rangeStart)
        case .incremental:
            guard let last = settings.lastSyncDate else { return nil }
            return Date().timeIntervalSince(last)
        }
    }

    private func spanText() -> String {
        switch settings.mode {
        case .range:
            let days = max(1, Int((settings.rangeEnd.timeIntervalSince(settings.rangeStart) / 86_400).rounded()))
            return "本次将导出指定时间段约 \(days) 天的数据。"
        case .incremental:
            if let last = settings.lastSyncDate {
                let days = max(1, Int((Date().timeIntervalSince(last) / 86_400).rounded()))
                return "本次将导出自上次同步约 \(days) 天的数据。"
            } else {
                return "尚未同步过，本次将导出全部历史数据，可能较多。"
            }
        }
    }

    // MARK: 确认流程

    private func presentConfirm() {
        let recent = settings.largeExportThresholdDays
        confirm = LargeExportConfirm(spanText: spanText(), estimatedCount: nil, recentDays: recent)

        let metrics = selectedMetricsInOrder
        let mode = settings.mode
        let start = rangeStartIfNeeded
        let end = rangeEndIfNeeded

        fetchTask?.cancel()
        pendingOutcome = nil
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.health.fetch(metrics: metrics, mode: mode, start: start, end: end)
                if Task.isCancelled { return }
                self.pendingOutcome = outcome
                self.confirm?.estimatedCount = outcome.samples.count
            } catch {
                if Task.isCancelled { return }
                self.confirm = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 继续导出全部：复用确认阶段已取的样本，不重复查询。
    func confirmContinueAll() {
        guard let outcome = pendingOutcome else { return }   // 估算未完成时按钮应禁用
        confirm = nil
        pendingOutcome = nil
        Task {
            isWorking = true
            defer { isWorking = false }
            await finishExport(outcome: outcome, isFullIncremental: outcome.isIncremental)
        }
    }

    /// 仅导出最近 N 天：取消进行中的全量查询，改跑局部 range 读取（不动 anchor / lastSyncDate）。
    func confirmRecentOnly() {
        let days = settings.largeExportThresholdDays
        let metrics = selectedMetricsInOrder
        confirm = nil
        fetchTask?.cancel()
        pendingOutcome = nil
        let end = Date()
        let start = end.addingTimeInterval(-Double(days) * 86_400)
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                let outcome = try await health.fetch(metrics: metrics, mode: .range, start: start, end: end)
                await finishExport(outcome: outcome, isFullIncremental: false)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func confirmCancel() {
        fetchTask?.cancel()
        pendingOutcome = nil
        confirm = nil
    }

    // MARK: 执行

    private func runExport(mode: SyncMode, start: Date?, end: Date?, isFullIncremental: Bool) {
        let metrics = selectedMetricsInOrder
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                let outcome = try await health.fetch(metrics: metrics, mode: mode, start: start, end: end)
                await finishExport(outcome: outcome, isFullIncremental: isFullIncremental)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 提交 anchor（仅全量增量）、编码 JSON、打开预览。
    private func finishExport(outcome: HealthKitManager.FetchOutcome, isFullIncremental: Bool) async {
        if isFullIncremental {
            health.commit(outcome)
            settings.lastSyncDate = Date()
        }
        samples = outcome.samples
        do {
            jsonString = try await Self.encodeJSON(makeEnvelope(samples: outcome.samples))
            statusMessage = "读取到 \(outcome.samples.count) 条样本。"
            showPreview = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 在后台线程编码，避免阻塞主线程。
    nonisolated private static func encodeJSON(_ envelope: ExportEnvelope) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try JSONExporter.string(envelope)
        }.value
    }

    // MARK: 发送

    func send() async {
        guard settings.hasEndpoint else {
            errorMessage = "未配置 API endpoint，可在设置中填写，或使用分享导出。"
            return
        }
        guard !jsonString.isEmpty else {
            errorMessage = "没有可发送的数据，请先读取。"
            return
        }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let sender = HTTPSender(endpoint: settings.endpoint,
                                    authorizationHeader: settings.authorizationHeader)
            let data = Data(jsonString.utf8)
            try await sender.send(data)
            statusMessage = "已发送 \(samples.count) 条样本。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeEnvelope(samples: [HealthSample]) -> ExportEnvelope {
        let device = ExportEnvelope.DeviceInfo(
            model: UIDevice.current.model,
            os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        )
        let range = ExportEnvelope.ExportRange(
            mode: settings.mode,
            start: settings.mode == .range ? settings.rangeStart : nil,
            end: settings.mode == .range ? settings.rangeEnd : nil
        )
        return ExportEnvelope(device: device, range: range, samples: samples)
    }
}
