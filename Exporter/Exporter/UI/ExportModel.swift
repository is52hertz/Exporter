//
//  ExportModel.swift
//  Exporter
//
//  UI 协调层：串起授权、读取、JSON 生成与发送，并暴露视图所需的状态。
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

    init() {
        self.settings = AppSettings()
        self.health = HealthKitManager()
    }

    init(settings: AppSettings, health: HealthKitManager) {
        self.settings = settings
        self.health = health
    }

    var canRead: Bool { !settings.selectedMetrics.isEmpty }

    /// 请求所有已注册指标的读取授权。
    func requestAuthorization() async {
        errorMessage = nil
        do {
            try await health.requestAuthorization(for: HealthMetric.registered)
            statusMessage = "已发起授权请求，请在系统弹窗中允许。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 按当前设置读取数据，生成 JSON 并打开预览。
    func readAndPreview() async {
        guard canRead else {
            errorMessage = "请至少选择一个指标。"
            return
        }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let metrics = selectedMetricsInOrder
            let start = settings.mode == .range ? settings.rangeStart : nil
            let end = settings.mode == .range ? settings.rangeEnd : nil
            let fetched = try await health.fetch(metrics: metrics,
                                                 mode: settings.mode,
                                                 start: start,
                                                 end: end)
            samples = fetched
            jsonString = try JSONExporter.string(makeEnvelope(samples: fetched))
            statusMessage = "读取到 \(fetched.count) 条样本。"
            showPreview = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 将当前 JSON 发送到配置的 endpoint。
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
            try await sender.send(Data(jsonString.utf8))
            statusMessage = "已发送 \(samples.count) 条样本。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var selectedMetricsInOrder: [HealthMetric] {
        HealthMetric.registered.filter { settings.selectedMetrics.contains($0) }
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
