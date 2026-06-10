//
//  Sender.swift
//  Exporter
//
//  可插拔的发送层：MVP 提供 HTTP POST 占位实现，认证方式确定后可替换/扩展。
//

import Foundation

/// 将已编码的 JSON 负载发送到目的地。
protocol ExportSender {
    func send(_ data: Data) async throws
}

enum SenderError: LocalizedError {
    case missingEndpoint
    case invalidURL(String)
    case httpStatus(Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "未配置 API endpoint。"
        case .invalidURL(let s):
            return "endpoint 不是合法 URL：\(s)"
        case .httpStatus(let code, let body):
            return "服务器返回 \(code)。\(body ?? "")"
        }
    }
}

/// 通过 HTTP POST 发送 JSON。endpoint 与可选 Authorization 头来自 AppSettings。
struct HTTPSender: ExportSender {
    let endpoint: String
    let authorizationHeader: String?
    var session: URLSession = .shared

    func send(_ data: Data) async throws {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SenderError.missingEndpoint }
        guard let url = URL(string: trimmed), url.scheme != nil else {
            throw SenderError.invalidURL(trimmed)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let header = authorizationHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !header.isEmpty {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data

        let (respData, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: respData, encoding: .utf8)
            throw SenderError.httpStatus(http.statusCode, body: body)
        }
    }
}
