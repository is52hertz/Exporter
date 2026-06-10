//
//  ExporterTests.swift
//  ExporterTests
//
//  Created by is52hertz on 2026/6/10.
//

import Testing
import Foundation
@testable import Exporter

struct ExporterTests {

    /// 固定输入构造一个信封，便于做稳定断言。
    private func makeEnvelope() -> ExportEnvelope {
        let start = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let end = start.addingTimeInterval(3600)
        let steps = HealthSample(type: "stepCount", category: "activity",
                                 value: 1234, stringValue: nil, unit: "count",
                                 start: start, end: end, source: "Apple Watch",
                                 uuid: "11111111-1111-1111-1111-111111111111")
        let sleep = HealthSample(type: "sleepAnalysis", category: "sleep",
                                 value: nil, stringValue: "asleepCore", unit: nil,
                                 start: start, end: end, source: "iPhone",
                                 uuid: "22222222-2222-2222-2222-222222222222")
        let device = ExportEnvelope.DeviceInfo(model: "iPhone", os: "iOS 26.5")
        let range = ExportEnvelope.ExportRange(mode: .incremental, start: nil, end: nil)
        return ExportEnvelope(device: device, range: range, samples: [steps, sleep],
                              exportedAt: Date(timeIntervalSince1970: 1_700_003_600))
    }

    @Test func encodesExpectedFields() throws {
        let json = try JSONExporter.string(makeEnvelope())

        #expect(json.contains("\"schemaVersion\" : 1"))
        #expect(json.contains("\"type\" : \"stepCount\""))
        #expect(json.contains("\"value\" : 1234"))
        #expect(json.contains("\"unit\" : \"count\""))
        #expect(json.contains("\"stringValue\" : \"asleepCore\""))
        // ISO8601 时间戳
        #expect(json.contains("2023-11-14T22:13:20Z"))
    }

    @Test func omitsNilOptionalsPerSampleKind() throws {
        let json = try JSONExporter.string(makeEnvelope())
        // 数值型样本不应带 stringValue；分类型样本不应带 value/unit。
        // 这里粗粒度校验：整段 JSON 不出现 null。
        #expect(!json.contains(": null"))
    }

    @Test func roundTrips() throws {
        let original = makeEnvelope()
        let data = try JSONExporter.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ExportEnvelope.self, from: data)

        #expect(decoded.schemaVersion == original.schemaVersion)
        #expect(decoded.samples.count == 2)
        #expect(decoded.samples.first?.type == "stepCount")
        #expect(decoded.samples.first?.value == 1234)
        #expect(decoded.range.mode == .incremental)
    }
}
