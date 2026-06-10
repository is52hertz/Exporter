//
//  HealthMetric.swift
//  Exporter
//
//  数据类型表：每个 metric 描述一种健康数据。
//  这里保持与 HealthKit 解耦（纯值类型），便于在模型/UI/测试中自由使用；
//  与 HKSampleType / HKUnit 的映射放在 HealthKitManager 的扩展中（仅 canImport(HealthKit) 平台）。
//

import Foundation

/// 数据大类，用于在 JSON 中分组与 UI 分区。
enum HealthCategory: String, Codable, CaseIterable, Identifiable {
    case activity   // 活动 / 健身
    case vitals     // 生命体征
    case body       // 身体测量
    case sleep      // 睡眠

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .activity: return "活动 / 健身"
        case .vitals:   return "生命体征"
        case .body:     return "身体测量"
        case .sleep:    return "睡眠"
        }
    }
}

/// 单个健康指标的描述符。新增指标只需在此添加一个 case 并补全映射。
enum HealthMetric: String, CaseIterable, Identifiable, Codable {
    case stepCount
    case activeEnergyBurned
    case heartRate
    case sleepAnalysis

    var id: String { rawValue }

    /// 样本形态：累计/离散数值 vs. 分类。
    enum Kind { case quantity, category }

    var kind: Kind {
        switch self {
        case .stepCount, .activeEnergyBurned, .heartRate: return .quantity
        case .sleepAnalysis: return .category
        }
    }

    var category: HealthCategory {
        switch self {
        case .stepCount, .activeEnergyBurned: return .activity
        case .heartRate:                      return .vitals
        case .sleepAnalysis:                  return .sleep
        }
    }

    /// 写入 JSON 的单位字符串；分类型样本为 nil。
    var unitString: String? {
        switch self {
        case .stepCount:          return "count"
        case .activeEnergyBurned: return "kcal"
        case .heartRate:          return "count/min"
        case .sleepAnalysis:      return nil
        }
    }

    var displayName: String {
        switch self {
        case .stepCount:          return "步数"
        case .activeEnergyBurned: return "活动能量"
        case .heartRate:          return "心率"
        case .sleepAnalysis:      return "睡眠分析"
        }
    }

    var systemImage: String {
        switch self {
        case .stepCount:          return "figure.walk"
        case .activeEnergyBurned: return "flame.fill"
        case .heartRate:          return "heart.fill"
        case .sleepAnalysis:      return "bed.double.fill"
        }
    }

    /// MVP 默认注册的指标集合。
    static var registered: [HealthMetric] { allCases }
}
