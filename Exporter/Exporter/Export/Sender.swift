//
//  Sender.swift
//  Exporter
//
//  可插拔的发送层：MVP 提供 HTTP POST 占位实现，认证方式确定后可替换/扩展。
//

import Foundation

/// 将已编码的 JSON 负载发送到目的地。
nonisolated protocol ExportSender: Sendable {
    func send(_ data: Data) async throws
}

nonisolated enum SenderError: LocalizedError {
    case missingEndpoint
    case invalidURL(String)
    case insecureScheme(String)
    case httpStatus(Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "未配置 API endpoint。"
        case .invalidURL(let s):
            return "endpoint 不是合法 URL：\(s)"
        case .insecureScheme(let s):
            return "endpoint 必须使用 https：\(s)"
        case .httpStatus(let code, let body):
            return "服务器返回 \(code)。\(body ?? "")"
        }
    }
}

/// 通过 HTTP POST 发送 JSON。endpoint 与可选 Authorization 头来自 AppSettings。
nonisolated struct HTTPSender: ExportSender {
    let endpoint: String
    let authorizationHeader: String?
    /// 默认会话使用只放行 https 重定向的代理，防止 https 地址 30x 跳到 http 后带着凭据明文发出。
    var session: URLSession = HTTPSender.makeSecureSession()

    static func makeSecureSession() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: HTTPSOnlyRedirectDelegate(), delegateQueue: nil)
    }

    /// 只接受带主机名的 https 地址；其余（http、无主机、其他协议）一律拒绝。
    static func validatedURL(_ s: String) -> URL? {
        guard let url = URL(string: s), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    func send(_ data: Data) async throws {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SenderError.missingEndpoint }
        guard let url = Self.validatedURL(trimmed) else {
            if let u = URL(string: trimmed), u.scheme != nil, u.scheme?.lowercased() != "https" {
                throw SenderError.insecureScheme(trimmed)
            }
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

/// 重定向目标不是 https 时拒绝跟随（返回 nil 即把 30x 响应原样交回，随后按非 2xx 报错）。
nonisolated final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func allows(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allows(request.url) ? request : nil)
    }
}
