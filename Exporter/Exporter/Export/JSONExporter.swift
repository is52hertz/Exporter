//
//  JSONExporter.swift
//  Exporter
//
//  将 ExportEnvelope 编码为稳定、可读的 JSON。
//

import Foundation

enum JSONExporter {
    /// 统一的编码器配置：ISO8601 时间、键排序、缩进。
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func encode(_ envelope: ExportEnvelope) throws -> Data {
        try makeEncoder().encode(envelope)
    }

    static func string(_ envelope: ExportEnvelope) throws -> String {
        let data = try encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }
}
