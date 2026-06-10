//
//  ExportProfile.swift
//  Exporter
//
//  个人特征（HealthKit Characteristics）：非样本数据，经 healthStore 访问器一次性读取，
//  作为 JSON 顶层 profile 对象导出。未授权 / 未设置的项为 nil（导出时省略）。
//

import Foundation

nonisolated struct ExportProfile: Sendable {
    var dateOfBirth: String?        // "1990-01-31"
    var biologicalSex: String?      // female / male / other
    var bloodType: String?          // aPositive / oNegative / …
    var fitzpatrickSkinType: String? // typeI … typeVI
    var wheelchairUse: String?      // yes / no
    var activityMoveMode: String?   // activeEnergy / appleMoveTime

    var isEmpty: Bool {
        dateOfBirth == nil && biologicalSex == nil && bloodType == nil
            && fitzpatrickSkinType == nil && wheelchairUse == nil && activityMoveMode == nil
    }

    /// 序列化顺序固定的键值对（nil 省略）。
    var fields: [(key: String, value: String)] {
        [("dateOfBirth", dateOfBirth), ("biologicalSex", biologicalSex),
         ("bloodType", bloodType), ("fitzpatrickSkinType", fitzpatrickSkinType),
         ("wheelchairUse", wheelchairUse), ("activityMoveMode", activityMoveMode)]
            .compactMap { key, value in value.map { (key, $0) } }
    }
}
