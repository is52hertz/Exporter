//
//  HealthSample.swift
//  Exporter
//
//  统一中间模型：从 HealthKit 读出的样本归一化为该结构，再编码为 JSON。
//

import Foundation

/// 归一化后的单条健康样本。quantity 样本填 `value`+`unit`；category 样本填 `stringValue`。
struct HealthSample: Codable, Identifiable, Hashable {
    /// 指标标识，对应 HealthMetric.rawValue，如 "stepCount" / "sleepAnalysis"。
    let type: String
    /// 数据大类：activity / vitals / body / sleep。
    let category: String
    /// 数值型取值（quantity 样本）。
    let value: Double?
    /// 分类型取值（category 样本），如 "asleepCore" / "inBed"。
    let stringValue: String?
    /// 单位字符串，如 "count" / "kcal" / "count/min"；category 样本为 nil。
    let unit: String?
    let start: Date
    let end: Date
    /// 数据来源 App / 设备名，如 "Apple Watch"。
    let source: String?
    /// HealthKit 样本 UUID，用于去重。
    let uuid: String

    var id: String { uuid }
}
