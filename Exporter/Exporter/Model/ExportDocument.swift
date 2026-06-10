//
//  ExportDocument.swift
//  Exporter
//
//  Schema v2 导出文档：按指标分组，columns/rows 紧凑行，来源去重为索引表。
//  由 [HealthSample] + 元信息构建，经 JSONExporter 序列化。
//

import Foundation

/// 导出负载顶层结构（schema v2）。
/// 相比 v1 的逐条对象：type/category/unit 提升到组级、source 用索引表去重、
/// 时间编码为 start + 时长秒，大幅缩短文件并更利于 LLM 解析。
nonisolated struct ExportDocument: Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let device: DeviceInfo
    let range: ExportRange
    /// 去重后的数据来源名；row 中的 source 列是该数组的下标。
    let sources: [String]
    let groups: [MetricGroup]

    static let currentSchemaVersion = 2

    struct DeviceInfo: Sendable {
        let model: String   // 如 "iPhone"
        let os: String      // 如 "iOS 26.5"
    }

    struct ExportRange: Sendable {
        let mode: SyncMode
        let start: Date?
        let end: Date?
    }

    /// 一个指标的全部样本。unit 仅 quantity 指标有；category 指标省略。
    struct MetricGroup: Sendable {
        let type: String        // HealthMetric.rawValue，如 "heartRate"
        let category: String
        let unit: String?
        let rows: [Row]
    }

    /// 单条样本的紧凑行。列序固定：start, durationSec, value, source[, uuid]。
    struct Row: Sendable {
        let start: Date
        let durationSec: Int
        let value: Value
        let sourceIndex: Int
        /// 仅当用户开启「包含 UUID」时携带。
        let uuid: String?

        enum Value: Sendable {
            case number(Double)   // quantity 样本
            case string(String)   // category 样本，如 "asleepCore"
        }
    }

    /// 由归一化样本构建：按指标分组（HealthMetric.registered 顺序，未知类型按字母序殿后），
    /// 组内保持传入顺序（fetch 已按 start 升序），来源去重并建索引。
    init(samples: [HealthSample],
         device: DeviceInfo,
         range: ExportRange,
         includeUUID: Bool,
         exportedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.device = device
        self.range = range

        var sourceIndices: [String: Int] = [:]
        var sources: [String] = []
        var rowsByType: [String: [Row]] = [:]
        var categoryByType: [String: String] = [:]
        var unitByType: [String: String?] = [:]

        for sample in samples {
            let sourceName = sample.source ?? "unknown"
            let sourceIndex: Int
            if let existing = sourceIndices[sourceName] {
                sourceIndex = existing
            } else {
                sourceIndex = sources.count
                sourceIndices[sourceName] = sourceIndex
                sources.append(sourceName)
            }

            let value: Row.Value
            if let number = sample.value {
                value = .number(number)
            } else {
                value = .string(sample.stringValue ?? "unknown")
            }
            let row = Row(start: sample.start,
                          durationSec: Int(sample.end.timeIntervalSince(sample.start).rounded()),
                          value: value,
                          sourceIndex: sourceIndex,
                          uuid: includeUUID ? sample.uuid : nil)
            rowsByType[sample.type, default: []].append(row)
            categoryByType[sample.type] = sample.category
            unitByType[sample.type] = sample.unit
        }

        let knownOrder = HealthMetric.registered.map(\.rawValue)
        let orderedTypes = knownOrder.filter { rowsByType[$0] != nil }
            + rowsByType.keys.filter { !knownOrder.contains($0) }.sorted()
        self.sources = sources
        self.groups = orderedTypes.map { type in
            MetricGroup(type: type,
                        category: categoryByType[type] ?? "unknown",
                        unit: unitByType[type] ?? nil,
                        rows: rowsByType[type] ?? [])
        }
    }
}
