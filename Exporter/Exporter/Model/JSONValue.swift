//
//  JSONValue.swift
//  Exporter
//
//  特殊样本附加列的递归 JSON 值类型（数字 / 字符串 / 嵌套数组）。
//  由 JSONExporter 序列化；保持纯数据、Sendable。
//

import Foundation

nonisolated indirect enum JSONValue: Hashable, Sendable {
    case number(Double)
    case string(String)
    case array([JSONValue])
    /// 序列化为 JSON null（仅用于嵌套数组中占位，如听力图单耳缺测）。
    case null
}
