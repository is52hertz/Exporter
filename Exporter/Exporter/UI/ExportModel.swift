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

    // 导出产物（大数据落盘，仅轻量摘要驻留内存，避免巨型字符串卡渲染）
    var exportFileURL: URL?
    var exportByteCount = 0
    var previewSnippet = ""
    var previewTruncated = false
    var sampleCount = 0
    var metricCounts: [MetricCount] = []
    var dataStart: Date?
    var dataEnd: Date?

    var isWorking = false
    var statusMessage: String?
    var errorMessage: String?
    var showPreview = false

    // 授权
    var authorizationDetermined = false
    var showAuthSettingsAlert = false
    /// 请求前的多面板流程说明（健康数据 + 用药 + 验光处方共三个系统面板依次弹出）。
    var showAuthFlowNotice = false

    // 各指标最近样本时间（保守探测：有=已授权且有数据；无=未授权或无数据）。
    // 懒探测：展开某分类时才查询该组，结果缓存；probedCategories 记录已探测的分类。
    var probeDates: [HealthMetric: Date] = [:]
    var probedCategories: Set<HealthCategory> = []

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

    /// 预览摘要里展示的单指标条数。后台任务中构造，需脱离 MainActor 隔离。
    nonisolated struct MetricCount: Identifiable, Sendable {
        let type: String
        let count: Int
        var id: String { type }

        var displayName: String {
            HealthMetric(rawValue: type)?.displayName ?? type
        }
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
        // 部分类型不出现在授权面板（地区/设备功能限制），系统状态会永远停在 shouldRequest；
        // 已成功请求过一次即视为已决（再请求面板也不会出现这些类型）。
        if settings.hasRequestedAuthorization {
            authorizationDetermined = true
        } else {
            authorizationDetermined = await health.isAuthorizationDetermined(for: HealthMetric.registered)
        }
    }

    /// 未决 → 先弹流程说明（授权分三个系统面板）；已决 → 弹说明（引导去设置）。
    func handleAuthorizationTap() {
        if authorizationDetermined {
            showAuthSettingsAlert = true
        } else {
            showAuthFlowNotice = true
        }
    }

    /// 用户确认流程说明后实际发起授权（依次弹出健康数据 / 用药 / 验光处方面板）。
    func proceedAuthorization() async {
        errorMessage = nil
        do {
            try await health.requestAuthorization(for: HealthMetric.registered)
            settings.hasRequestedAuthorization = true
            statusMessage = "授权流程已完成。"
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshAuthorizationState()
        await reprobeKnownCategories()
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: 探测（懒加载：按分类）

    /// 探测一个分类下所有指标的最近样本时间；已探测过的分类直接命中缓存。
    func probeCategory(_ category: HealthCategory) async {
        guard !probedCategories.contains(category) else { return }
        probedCategories.insert(category)
        let metrics = HealthMetric.registered.filter { $0.category == category }
        let results = await withTaskGroup(of: (HealthMetric, Date?).self) { group -> [(HealthMetric, Date?)] in
            for metric in metrics {
                group.addTask { (metric, await self.health.probeLatest(metric)) }
            }
            var acc: [(HealthMetric, Date?)] = []
            for await pair in group { acc.append(pair) }
            return acc
        }
        for (metric, date) in results where date != nil { probeDates[metric] = date }
    }

    /// 授权状态变化后重新探测已展开过的分类（清缓存重查）。
    func reprobeKnownCategories() async {
        let known = probedCategories
        probedCategories = []
        probeDates = [:]
        for category in known {
            await probeCategory(category)
        }
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

    /// 提交 anchor（仅全量增量）、序列化并落盘 JSON、打开预览。
    private func finishExport(outcome: HealthKitManager.FetchOutcome, isFullIncremental: Bool) async {
        if isFullIncremental {
            health.commit(outcome)
            settings.lastSyncDate = Date()
        }
        let device = ExportDocument.DeviceInfo(
            model: UIDevice.current.model,
            os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        )
        let range = ExportDocument.ExportRange(
            mode: settings.mode,
            start: settings.mode == .range ? settings.rangeStart : nil,
            end: settings.mode == .range ? settings.rangeEnd : nil
        )
        do {
            let health = self.health
            let profile = await Task.detached(priority: .userInitiated) { health.readProfile() }.value
            let artifact = try await Self.produceArtifact(samples: outcome.samples,
                                                          device: device,
                                                          range: range,
                                                          includeUUID: settings.includeUUID,
                                                          profile: profile,
                                                          replacing: exportFileURL)
            exportFileURL = artifact.fileURL
            exportByteCount = artifact.byteCount
            previewSnippet = artifact.snippet
            previewTruncated = artifact.truncated
            sampleCount = artifact.sampleCount
            metricCounts = artifact.metricCounts
            dataStart = artifact.dataStart
            dataEnd = artifact.dataEnd
            var message = "读取到 \(artifact.sampleCount) 条样本。"
            if !outcome.skippedMetrics.isEmpty {
                let names = outcome.skippedMetrics.prefix(3).map(\.displayName).joined(separator: "、")
                let suffix = outcome.skippedMetrics.count > 3 ? " 等" : ""
                message += "跳过 \(outcome.skippedMetrics.count) 项未授权指标（\(names)\(suffix)）。"
            }
            statusMessage = message
            showPreview = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 后台产物：JSON 文件 + 截断预览 + 摘要。主线程只接收这份轻量结构。
    nonisolated private struct ExportArtifact: Sendable {
        let fileURL: URL
        let byteCount: Int
        let snippet: String
        let truncated: Bool
        let sampleCount: Int
        let metricCounts: [MetricCount]
        let dataStart: Date?
        let dataEnd: Date?
    }

    /// 预览片段最大字节数；之外的内容只进文件，避免超长 Text 卡死主线程布局。
    nonisolated private static let previewByteLimit = 64 * 1024

    /// 在后台线程序列化、写临时文件并裁出预览片段，避免阻塞主线程。
    nonisolated private static func produceArtifact(samples: [HealthSample],
                                                    device: ExportDocument.DeviceInfo,
                                                    range: ExportDocument.ExportRange,
                                                    includeUUID: Bool,
                                                    profile: ExportProfile?,
                                                    replacing previousURL: URL?) async throws -> ExportArtifact {
        try await Task.detached(priority: .userInitiated) {
            let document = ExportDocument(samples: samples, device: device,
                                          range: range, includeUUID: includeUUID,
                                          profile: profile)
            let data = JSONExporter.encode(document)

            if let previousURL {
                try? FileManager.default.removeItem(at: previousURL)
            }
            let stamp = Date().formatted(.iso8601.year().month().day()
                .timeSeparator(.omitted).dateSeparator(.omitted).time(includingFractionalSeconds: false))
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("HealthExport-\(stamp).json")
            try data.write(to: fileURL, options: .atomic)

            let (snippet, truncated) = Self.makeSnippet(from: data)
            var counts: [(String, Int)] = []
            for group in document.groups {
                counts.append((group.type, group.rows.count))
            }
            return ExportArtifact(fileURL: fileURL,
                                  byteCount: data.count,
                                  snippet: snippet,
                                  truncated: truncated,
                                  sampleCount: samples.count,
                                  metricCounts: counts.map { MetricCount(type: $0.0, count: $0.1) },
                                  dataStart: samples.first?.start,
                                  dataEnd: samples.last?.end)
        }.value
    }

    /// 取 JSON 开头若干 KB 作预览，按行边界截断，保证 UTF-8 合法。
    nonisolated private static func makeSnippet(from data: Data) -> (String, Bool) {
        guard data.count > previewByteLimit else {
            return (String(decoding: data, as: UTF8.self), false)
        }
        var head = data.prefix(previewByteLimit)
        if let lastNewline = head.lastIndex(of: UInt8(ascii: "\n")) {
            head = head[..<lastNewline]
        }
        return (String(decoding: head, as: UTF8.self), true)
    }

    // MARK: 发送

    func send() async {
        guard settings.hasEndpoint else {
            errorMessage = "未配置 API endpoint，可在设置中填写，或使用分享导出。"
            return
        }
        guard let fileURL = exportFileURL else {
            errorMessage = "没有可发送的数据，请先读取。"
            return
        }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let sender = HTTPSender(endpoint: settings.endpoint,
                                    authorizationHeader: settings.authorizationHeader)
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: fileURL)
            }.value
            try await sender.send(data)
            statusMessage = "已发送 \(sampleCount) 条样本。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
