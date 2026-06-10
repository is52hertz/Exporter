//
//  JSONExporter.swift
//  Exporter
//
//  将 ExportDocument 序列化为稳定、可读的 JSON（schema v2）。
//  自定义字符串构建而非 JSONEncoder：顶层美化缩进、每条样本 row 单行、
//  整数值不带小数点 —— 比 Codable + .prettyPrinted 快得多，排版也可控。
//

import Foundation

nonisolated enum JSONExporter {
    /// ISO8601DateFormatter 线程安全，可跨后台任务共享。
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(_ document: ExportDocument) -> String {
        let rowCount = document.groups.reduce(0) { $0 + $1.rows.count }
        var out = String()
        out.reserveCapacity(rowCount * 56 + 1024)

        out += "{\n"
        out += "  \"schemaVersion\": \(document.schemaVersion),\n"
        out += "  \"exportedAt\": \(quoted(date: document.exportedAt)),\n"
        out += "  \"device\": { \"model\": \(quoted(document.device.model)), \"os\": \(quoted(document.device.os)) },\n"
        out += "  \"range\": \(rangeObject(document.range)),\n"
        out += "  \"sources\": [\(document.sources.map(quoted).joined(separator: ", "))],\n"
        out += "  \"metrics\": {"

        for (groupIndex, group) in document.groups.enumerated() {
            out += groupIndex == 0 ? "\n" : ",\n"
            append(group, to: &out)
        }
        out += document.groups.isEmpty ? "}\n" : "\n  }\n"
        out += "}\n"
        return out
    }

    static func encode(_ document: ExportDocument) -> Data {
        Data(string(document).utf8)
    }

    // MARK: 组与行

    private static func append(_ group: ExportDocument.MetricGroup, to out: inout String) {
        let includesUUID = group.rows.contains { $0.uuid != nil }
        var columns = ["start", "durationSec", "value", "source"]
        if includesUUID { columns.append("uuid") }

        out += "    \(quoted(group.type)): {\n"
        out += "      \"category\": \(quoted(group.category)),\n"
        if let unit = group.unit {
            out += "      \"unit\": \(quoted(unit)),\n"
        }
        out += "      \"count\": \(group.rows.count),\n"
        out += "      \"columns\": [\(columns.map(quoted).joined(separator: ", "))],\n"
        out += "      \"rows\": ["
        for (rowIndex, row) in group.rows.enumerated() {
            out += rowIndex == 0 ? "\n" : ",\n"
            out += "        ["
            out += quoted(date: row.start)
            out += ", \(row.durationSec), "
            switch row.value {
            case .number(let number): out += numberString(number)
            case .string(let string): out += quoted(string)
            }
            out += ", \(row.sourceIndex)"
            if includesUUID {
                out += ", \(quoted(row.uuid ?? ""))"
            }
            out += "]"
        }
        out += group.rows.isEmpty ? "]\n" : "\n      ]\n"
        out += "    }"
    }

    private static func rangeObject(_ range: ExportDocument.ExportRange) -> String {
        var fields = ["\"mode\": \(quoted(range.mode.rawValue))"]
        if let start = range.start { fields.append("\"start\": \(quoted(date: start))") }
        if let end = range.end { fields.append("\"end\": \(quoted(date: end))") }
        return "{ \(fields.joined(separator: ", ")) }"
    }

    // MARK: 标量

    /// 整数值输出为整数（72 而非 72.0），其余用 Swift 最短往返表示。
    private static func numberString(_ value: Double) -> String {
        guard value.isFinite else { return "null" }   // JSON 无 NaN/Inf；正常数据不会走到
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func quoted(date: Date) -> String {
        "\"\(dateFormatter.string(from: date))\""
    }

    /// JSON 字符串转义（不转义斜杠，等价 .withoutEscapingSlashes）。
    private static func quoted(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"":     out += "\\\""
            case "\\":     out += "\\\\"
            case "\n":     out += "\\n"
            case "\r":     out += "\\r"
            case "\t":     out += "\\t"
            case "\u{00}"..."\u{1F}":
                out += String(format: "\\u%04x", scalar.value)
            default:       out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
