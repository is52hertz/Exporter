//
//  SyncMode.swift
//  Exporter
//
//  同步模式：增量（基于 anchor）或指定日期段。
//

import Foundation

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
