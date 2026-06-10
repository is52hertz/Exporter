//
//  ExporterTests.swift
//  ExporterTests
//
//  JSONExporter / ExportDocument（schema v2）单测：
//  固定输入断言结构、紧凑行排版、来源索引、UUID 开关与可选省略约定。
//

import Testing
import Foundation
@testable import Exporter

struct ExporterTests {

    /// 固定输入构造样本，便于做稳定断言。
    private func makeSamples() -> [HealthSample] {
        let start = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let steps = HealthSample(type: "stepCount", category: "activity",
                                 value: 1234, stringValue: nil, unit: "count",
                                 start: start, end: start.addingTimeInterval(600),
                                 source: "Apple Watch",
                                 uuid: "11111111-1111-1111-1111-111111111111")
        let heart = HealthSample(type: "heartRate", category: "vitals",
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

    private func makeDocument(includeUUID: Bool = false) -> ExportDocument {
        ExportDocument(samples: makeSamples(),
                       device: .init(model: "iPhone", os: "iOS 26.5"),
                       range: .init(mode: .incremental, start: nil, end: nil),
                       includeUUID: includeUUID,
                       exportedAt: Date(timeIntervalSince1970: 1_700_003_600))
    }

    @Test func encodesV2Structure() throws {
        let json = JSONExporter.string(makeDocument())

        #expect(json.contains("\"schemaVersion\": 2"))
        #expect(json.contains("\"sources\": [\"Apple Watch\", \"iPhone\"]"))
        #expect(json.contains("\"stepCount\": {"))
        #expect(json.contains("\"unit\": \"count/min\""))
        #expect(json.contains("\"columns\": [\"start\", \"durationSec\", \"value\", \"source\"]"))
        // ISO8601 时间戳
        #expect(json.contains("2023-11-14T22:13:20Z"))
    }

    @Test func rowsAreCompactSingleLines() throws {
        let json = JSONExporter.string(makeDocument())
        // 每条 row 单行：起始时间、时长、取值、来源索引同处一行。
        #expect(json.contains("[\"2023-11-14T22:13:20Z\", 600, 1234, 0]"))      // 整数值不带 .0
        #expect(json.contains("[\"2023-11-14T22:14:20Z\", 0, 73.5, 0]"))        // 瞬时样本时长 0，小数保留
        #expect(json.contains("[\"2023-11-14T22:13:20Z\", 3600, \"asleepCore\", 1]")) // category 值为字符串
        #expect(!json.contains("1234.0"))
    }

    @Test func parsesAsValidJSON() throws {
        let data = JSONExporter.encode(makeDocument())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let root = try #require(object)

        #expect(root["schemaVersion"] as? Int == 2)
        let metrics = try #require(root["metrics"] as? [String: Any])
        #expect(metrics.count == 3)
        let sleep = try #require(metrics["sleepAnalysis"] as? [String: Any])
        #expect(sleep["count"] as? Int == 1)
        #expect(sleep["unit"] == nil)   // category 指标省略 unit
        let rows = try #require(sleep["rows"] as? [[Any]])
        #expect(rows.first?.count == 4)
        // 可选省略约定：全文无 null
        #expect(!JSONExporter.string(makeDocument()).contains("null"))
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

    @Test func deduplicatesSources() throws {
        let document = makeDocument()
        #expect(document.sources == ["Apple Watch", "iPhone"])
        // 组按 HealthMetric.registered 顺序输出
        #expect(document.groups.map(\.type) == ["stepCount", "heartRate", "sleepAnalysis"])
    }
}
