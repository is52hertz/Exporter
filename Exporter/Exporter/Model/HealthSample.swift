//
//  HealthSample.swift
//  Exporter
//
//  统一中间模型：从 HealthKit 读出的样本归一化为该结构，再编码为 JSON。
//

import Foundation

/// 归一化后的单条健康样本。quantity 样本填 `value`+`unit`；category 样本填 `stringValue`。
/// 标记 nonisolated：纯数据 + Codable，需在后台线程编码，不应受默认 MainActor 隔离约束。
nonisolated struct HealthSample: Identifiable, Hashable, Sendable {
    /// 指标标识，对应 HealthMetric.rawValue，如 "stepCount" / "sleepAnalysis"。
    let type: String
    /// 数据大类，对应 HealthCategory.rawValue，如 "activity" / "heart"。
    let category: String
    /// 数值型取值（quantity 样本及特殊类型的主数值）。
    let value: Double?
    /// 分类型取值（category 样本及特殊类型的主字符串），如 "asleepCore" / "running"。
    let stringValue: String?
    /// 单位字符串，如 "count" / "kcal" / "count/min"；category 样本为 nil。
    let unit: String?
    let start: Date
    let end: Date
    /// 数据来源 App / 设备名，如 "Apple Watch"。
    let source: String?
    /// HealthKit 样本 UUID，用于去重。
    let uuid: String
    /// 特殊类型的附加列值，与 HealthMetric.extraColumns 位置一一对应；普通样本为 nil。
    let extra: [JSONValue]?

    var id: String { uuid }

    init(type: String, category: String, value: Double?, stringValue: String?,
         unit: String?, start: Date, end: Date, source: String?, uuid: String,
         extra: [JSONValue]? = nil) {
        self.type = type
        self.category = category
        self.value = value
        self.stringValue = stringValue
        self.unit = unit
        self.start = start
        self.end = end
        self.source = source
        self.uuid = uuid
        self.extra = extra
    }
}
