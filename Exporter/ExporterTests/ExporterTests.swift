//
//  ExporterTests.swift
//  ExporterTests
//
//  覆盖：目录完整性、HK 类型/单位映射兼容性、category 值名称表、
//  JSONExporter / ExportDocument（schema v3）序列化格式锁定。
//

import Testing
import Foundation
import HealthKit
@testable import Exporter

// MARK: - 目录与 HK 映射

struct CatalogTests {

    @Test func catalogIsCompleteAndUnique() throws {
        let metrics = HealthMetric.registered
        #expect(metrics.count == 197)
        #expect(Set(metrics.map(\.rawValue)).count == metrics.count)
        // 每项都有中文显示名
        #expect(metrics.allSatisfy { !$0.displayName.isEmpty })
        // 旧版四指标的 rawValue 不变（anchor / 设置持久化兼容）
        for legacy in ["stepCount", "activeEnergyBurned", "heartRate", "sleepAnalysis"] {
            #expect(HealthMetric(rawValue: legacy) != nil)
        }
        // 形态计数：120 quantity + 69 category + 8 特殊
        #expect(metrics.count { $0.kind == .quantity } == 120)
        #expect(metrics.count { $0.kind == .category } == 69)
    }

    @Test func everyMetricResolvesToSampleType() throws {
        // 标识符拼写（含 VO2Max / UVExposure / GAD7 等特例）全量校验
        for metric in HealthMetric.registered {
            #expect(metric.sampleType != nil, "无法解析 HK 类型：\(metric.rawValue)")
        }
    }

    @Test func everyQuantityUnitIsCompatible() throws {
        for metric in HealthMetric.registered where metric.kind == .quantity {
            let unit = try #require(metric.hkUnit, "缺单位映射：\(metric.rawValue)")
            let type = try #require(metric.sampleType as? HKQuantityType, "\(metric.rawValue)")
            #expect(type.is(compatibleWith: unit), "单位不兼容：\(metric.rawValue) ← \(unit)")
        }
    }

    @Test func categoryValueNames() throws {
        func metric(_ raw: String) -> HealthMetric { HealthMetric(rawValue: raw)! }
        // 睡眠阶段
        #expect(HealthKitManager.categoryValueName(metric: metric("sleepAnalysis"), rawValue: 3) == "asleepCore")
        // 症状 severity
        #expect(HealthKitManager.categoryValueName(metric: metric("headache"), rawValue: 2) == "mild")
        #expect(HealthKitManager.categoryValueName(metric: metric("fever"), rawValue: 4) == "severe")
        // 事件型 notApplicable → occurred
        #expect(HealthKitManager.categoryValueName(metric: metric("mindfulSession"), rawValue: 0) == "occurred")
        // 已知枚举
        #expect(HealthKitManager.categoryValueName(metric: metric("menstrualFlow"), rawValue: 2) == "light")
        #expect(HealthKitManager.categoryValueName(metric: metric("appleStandHour"), rawValue: 0) == "stood")
        #expect(HealthKitManager.categoryValueName(metric: metric("ovulationTestResult"), rawValue: 2) == "luteinizingHormoneSurge")
        // 越界回退
        #expect(HealthKitManager.categoryValueName(metric: metric("menstrualFlow"), rawValue: 99) == "value99")
    }

    @Test func perObjectAuthTypesProbeSafely() async throws {
        // 视力处方/用药记录走逐对象授权：未授权时探测必须安静返回 nil，
        // 且不得触发 HealthKit 的 NSException（曾导致启动即崩）。
        let manager = await MainActor.run { HealthKitManager() }
        for raw in ["visionPrescription", "medicationDoseEvent"] {
            let metric = try #require(HealthMetric(rawValue: raw))
            _ = await manager.probeLatest(metric)
        }
    }

    @Test func workoutActivityNames() throws {
        #expect(HealthKitManager.workoutActivityName(.running) == "running")
        #expect(HealthKitManager.workoutActivityName(.traditionalStrengthTraining) == "traditionalStrengthTraining")
        // 已废弃 case 经 rawValue 回退表
        #expect(HealthKitManager.workoutActivityName(HKWorkoutActivityType(rawValue: 14)!) == "dance")
    }
}

// MARK: - 序列化（schema v3）

struct ExporterTests {

    /// 固定输入构造样本，便于做稳定断言。
    private func makeSamples() -> [HealthSample] {
        let start = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let steps = HealthSample(type: "stepCount", category: "activity",
                                 value: 1234, stringValue: nil, unit: "count",
                                 start: start, end: start.addingTimeInterval(600),
                                 source: "Apple Watch",
                                 uuid: "11111111-1111-1111-1111-111111111111")
        let heart = HealthSample(type: "heartRate", category: "heart",
                                 value: 73.5, stringValue: nil, unit: "count/min",
                                 start: start.addingTimeInterval(60),
                                 end: start.addingTimeInterval(60),
                                 source: "Apple Watch",
                                 uuid: "33333333-3333-3333-3333-333333333333")
        let sleep = HealthSample(type: "sleepAnalysis", category: "sleep",
                                 value: nil, stringValue: "asleepCore", unit: nil,
                                 start: start, end: start.addingTimeInterval(3600),
                                 source: "iPhone",
                                 uuid: "22222222-2222-2222-2222-222222222222")
        return [steps, heart, sleep]
    }

    /// 特殊类型样本：体能训练（extra 含 null）与心境（嵌套字符串数组）。
    private func makeSpecialSamples() -> [HealthSample] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let workout = HealthSample(type: "workout", category: "workout",
                                   value: nil, stringValue: "running", unit: nil,
                                   start: start, end: start.addingTimeInterval(1800),
                                   source: "Apple Watch",
                                   uuid: "44444444-4444-4444-4444-444444444444",
                                   extra: [.number(320), .null])
        let mood = HealthSample(type: "stateOfMind", category: "mindfulness",
                                value: 0.5, stringValue: nil, unit: nil,
                                start: start, end: start,
                                source: "iPhone",
                                uuid: "55555555-5555-5555-5555-555555555555",
                                extra: [.string("momentaryEmotion"), .string("pleasant"),
                                        .array([.string("happy"), .string("calm")]),
                                        .array([.string("fitness")])])
        return [workout, mood]
    }

    private func makeDocument(samples: [HealthSample]? = nil,
                              includeUUID: Bool = false,
                              profile: ExportProfile? = nil) -> ExportDocument {
        ExportDocument(samples: samples ?? makeSamples(),
                       device: .init(model: "iPhone", os: "iOS 26.5"),
                       range: .init(mode: .incremental, start: nil, end: nil),
                       includeUUID: includeUUID,
                       profile: profile,
                       exportedAt: Date(timeIntervalSince1970: 1_700_003_600))
    }

    @Test func encodesV3Structure() throws {
        let json = JSONExporter.string(makeDocument())

        #expect(json.contains("\"schemaVersion\": 3"))
        #expect(json.contains("\"sources\": [\"Apple Watch\", \"iPhone\"]"))
        #expect(json.contains("\"stepCount\": {"))
        #expect(json.contains("\"unit\": \"count/min\""))
        #expect(json.contains("\"columns\": [\"start\", \"durationSec\", \"value\", \"source\"]"))
        #expect(json.contains("2023-11-14T22:13:20Z"))
        // 普通样本不含 profile、不含 null
        #expect(!json.contains("\"profile\""))
        #expect(!json.contains("null"))
    }

    @Test func rowsAreCompactSingleLines() throws {
        let json = JSONExporter.string(makeDocument())
        #expect(json.contains("[\"2023-11-14T22:13:20Z\", 600, 1234, 0]"))      // 整数值不带 .0
        #expect(json.contains("[\"2023-11-14T22:14:20Z\", 0, 73.5, 0]"))        // 瞬时样本时长 0
        #expect(json.contains("[\"2023-11-14T22:13:20Z\", 3600, \"asleepCore\", 1]"))
        #expect(!json.contains("1234.0"))
    }

    @Test func specialGroupsCarryExtraColumns() throws {
        let json = JSONExporter.string(makeDocument(samples: makeSpecialSamples()))

        // 体能训练：附加列 + 缺测 null 占位
        #expect(json.contains("\"columns\": [\"start\", \"durationSec\", \"value\", \"source\", \"kcal\", \"distanceKm\"]"))
        #expect(json.contains("[\"2023-11-14T22:13:20Z\", 1800, \"running\", 0, 320, null]"))
        // 心境：嵌套数组保持单行紧凑
        #expect(json.contains("\"columns\": [\"start\", \"durationSec\", \"value\", \"source\", \"kind\", \"classification\", \"labels\", \"associations\"]"))
        #expect(json.contains("0.5, 1, \"momentaryEmotion\", \"pleasant\", [\"happy\", \"calm\"], [\"fitness\"]]"))

        let data = JSONExporter.encode(makeDocument(samples: makeSpecialSamples()))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metrics = try #require(root["metrics"] as? [String: Any])
        let workout = try #require(metrics["workout"] as? [String: Any])
        let rows = try #require(workout["rows"] as? [[Any]])
        #expect(rows.first?.count == 6)
    }

    @Test func profileObjectIsEmittedWhenPresent() throws {
        var profile = ExportProfile()
        profile.dateOfBirth = "1990-01-31"
        profile.biologicalSex = "male"
        let json = JSONExporter.string(makeDocument(profile: profile))
        #expect(json.contains("\"profile\": { \"dateOfBirth\": \"1990-01-31\", \"biologicalSex\": \"male\" }"))

        // 空 profile 省略
        let empty = JSONExporter.string(makeDocument(profile: ExportProfile()))
        #expect(!empty.contains("\"profile\""))
    }

    @Test func parsesAsValidJSON() throws {
        let data = JSONExporter.encode(makeDocument())
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(root["schemaVersion"] as? Int == 3)
        let metrics = try #require(root["metrics"] as? [String: Any])
        #expect(metrics.count == 3)
        let sleep = try #require(metrics["sleepAnalysis"] as? [String: Any])
        #expect(sleep["count"] as? Int == 1)
        #expect(sleep["unit"] == nil)   // category 指标省略 unit
        let rows = try #require(sleep["rows"] as? [[Any]])
        #expect(rows.first?.count == 4)
    }

    @Test func uuidToggleAppendsColumn() throws {
        let withUUID = JSONExporter.string(makeDocument(includeUUID: true))
        #expect(withUUID.contains("\"columns\": [\"start\", \"durationSec\", \"value\", \"source\", \"uuid\"]"))
        #expect(withUUID.contains("\"11111111-1111-1111-1111-111111111111\"]"))

        let withoutUUID = JSONExporter.string(makeDocument(includeUUID: false))
        #expect(!withoutUUID.contains("uuid"))
        #expect(!withoutUUID.contains("11111111"))
    }

    @Test func rangeModeCarriesStartEnd() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let document = ExportDocument(samples: [],
                                      device: .init(model: "iPhone", os: "iOS 26.5"),
                                      range: .init(mode: .range, start: start,
                                                   end: start.addingTimeInterval(86_400)),
                                      includeUUID: false)
        let json = JSONExporter.string(document)
        #expect(json.contains("\"mode\": \"range\""))
        #expect(json.contains("\"start\": \"2023-11-14T22:13:20Z\""))
        #expect(json.contains("\"metrics\": {}"))

        let data = JSONExporter.encode(document)
        #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: data) }
    }

    @Test func deduplicatesSourcesAndOrdersGroups() throws {
        let document = makeDocument()
        #expect(document.sources == ["Apple Watch", "iPhone"])
        // 组按 HealthMetric.registered 顺序输出（activity → heart → sleep）
        #expect(document.groups.map(\.type) == ["stepCount", "heartRate", "sleepAnalysis"])
    }
}
