//
//  ExportEnvelope.swift
//  Exporter
//
//  JSON 顶层信封：发送/导出的完整负载结构。
//

import Foundation

/// 同步模式：增量（基于 anchor）或指定日期段。
nonisolated enum SyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case incremental
    case range

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .incremental: return "增量（自上次）"
        case .range:       return "指定时间段"
        }
    }
}

/// 导出负载顶层结构，可被 JSONExporter 编码。
nonisolated struct ExportEnvelope: Codable, Sendable {
    /// schema 版本，便于接收方兼容演进。
    let schemaVersion: Int
    let exportedAt: Date
    let device: DeviceInfo
    let range: ExportRange
    let samples: [HealthSample]

    static let currentSchemaVersion = 1

    struct DeviceInfo: Codable {
        let model: String   // 如 "iPhone"
        let os: String      // 如 "iOS 26.5"
    }

    struct ExportRange: Codable {
        let mode: SyncMode
        let start: Date?
        let end: Date?
    }

    init(device: DeviceInfo,
         range: ExportRange,
         samples: [HealthSample],
         exportedAt: Date = Date(),
         schemaVersion: Int = ExportEnvelope.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.device = device
        self.range = range
        self.samples = samples
    }
}
