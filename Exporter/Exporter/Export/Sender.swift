//
//  Sender.swift
//  Exporter
//
//  可插拔的 JSON 发送层。
//

import CFNetwork
import Darwin
import Foundation
import os

/// 将已编码的 JSON 负载发送到目的地。
nonisolated protocol ExportSender: Sendable {
    func send(_ data: Data) async throws -> SendReceipt
}

nonisolated struct SendReceipt: Codable, Equatable, Sendable {
    enum Destination: String, Codable, Sendable { case primary, backup }
    enum Origin: String, Codable, Sendable { case manual, background }

    let destination: Destination
    let host: String
    // Older saved receipts have no confirmation time or origin.
    let confirmedAt: Date?
    let origin: Origin?

    init(destination: Destination, host: String, confirmedAt: Date? = nil, origin: Origin? = nil) {
        self.destination = destination
        self.host = host
        self.confirmedAt = confirmedAt
        self.origin = origin
    }

    func dated(at date: Date, origin: Origin = .manual) -> Self {
        Self(destination: destination, host: host, confirmedAt: date, origin: origin)
    }
}

nonisolated enum SenderError: LocalizedError {
    case missingEndpoint
    case invalidURL(String)
    case insecureScheme(String)
    case invalidBackupEndpoint
    case unconfirmedDelivery
    case interruptedSuccessResponse(Int)
    case httpStatus(Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "未配置 API endpoint。"
        case .invalidURL(let s):
            return "endpoint 不是合法 URL：\(s)"
        case .insecureScheme(let s):
            return "主地址必须使用 https：\(s)"
        case .invalidBackupEndpoint:
            return "备用地址无效。请使用 https://；http:// 只能用于局域网地址。"
        case .unconfirmedDelivery:
            return "发送结果未确认。接收端可能已经收到数据，请确认后再决定是否重发。"
        case .interruptedSuccessResponse(let code):
            return "服务器返回 \(code)，但响应未接收完整。请在接收端确认后再决定是否重发。"
        case .httpStatus(let code, let body):
            return "服务器返回 \(code)。\(body ?? "")"
        }
    }
}

/// Serializes revocation with the synchronous start of any POST using this configuration.
nonisolated final class POSTStartAuthorization: Sendable {
    private let valid = OSAllocatedUnfairLock(initialState: true)

    init() {}

    func invalidate() {
        valid.withLock { $0 = false }
    }

    func withValidPermission<T: Sendable>(_ action: @Sendable () -> T) -> T? {
        valid.withLock { valid in
            guard valid else { return nil }
            return action()
        }
    }
}

/// 通过 HTTP POST 发送 JSON。地址与可选 Authorization 头来自 AppSettings。
nonisolated struct HTTPSender: ExportSender {
    let endpoint: String
    let backupEndpoint: String
    let authorizationHeader: String?
    let session: URLSession
    private let startAuthorization: POSTStartAuthorization?

    init(endpoint: String, backupEndpoint: String = "", authorizationHeader: String?,
         session: URLSession = HTTPSender.secureSession, startAuthorization: POSTStartAuthorization? = nil) {
        self.endpoint = endpoint
        self.backupEndpoint = backupEndpoint
        self.authorizationHeader = authorizationHeader
        self.session = session
        self.startAuthorization = startAuthorization
    }

    /// 保留手动与后台的共享会话和各自的时限。
    static let secureSession = makeSession(background: false, directHTTP: false)
    static let backgroundSession = makeSession(background: true, directHTTP: false)
    static let directHTTPBackupSession = makeSession(background: false, directHTTP: true)
    static let directHTTPBackgroundBackupSession = makeSession(background: true, directHTTP: true)

    private static func makeSession(background: Bool, directHTTP: Bool) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        if background {
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
        }
        if directHTTP {
            // Explicitly disable app-session proxies and PAC. Use the public proxy-dictionary
            // key strings where the corresponding CFNetwork constants are macOS-only.
            // This does not control OS/network routing or resolution of a configured .local name.
            config.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: 0,
                                                kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
                                                "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        }
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// 只接受带主机名的 https 地址；其余（http、无主机、其他协议）一律拒绝。
    static func validatedURL(_ s: String) -> URL? {
        guard let url = URL(string: s), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func validatedBackupURL(_ s: String) -> URL? {
        BackupEndpointPolicy.validatedURL(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    func send(_ data: Data) async throws -> SendReceipt {
        let startAuthorization = self.startAuthorization
        return try await route(data) { request, session in
            await Self.perform(request, session: session, startAuthorization: startAuthorization)
        }
    }

    /// Injectable transport for testing the actual routing and retry policy without networking.
    func send(_ data: Data, attempt: @Sendable (URLRequest, URLSession) async -> POSTOutcome) async throws -> SendReceipt {
        let startAuthorization = self.startAuthorization
        return try await route(data) { request, session in
            if let startAuthorization, startAuthorization.withValidPermission({ true }) == nil { return .notStarted }
            return await attempt(request, session)
        }
    }

    private func route(_ data: Data, attempt: @Sendable (URLRequest, URLSession) async -> POSTOutcome) async throws -> SendReceipt {
        try Task.checkCancellation()
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SenderError.missingEndpoint }
        guard let primary = Self.validatedURL(trimmed) else {
            if let u = URL(string: trimmed), u.scheme != nil, u.scheme?.lowercased() != "https" {
                throw SenderError.insecureScheme(trimmed)
            }
            throw SenderError.invalidURL(trimmed)
        }

        let backup = backupEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let backupURL: URL?
        if backup.isEmpty {
            backupURL = nil
        } else {
            guard let validated = Self.validatedBackupURL(backup) else { throw SenderError.invalidBackupEndpoint }
            backupURL = validated
        }

        let primaryOutcome = await attempt(request(for: primary, data: data, shortIdleTimeout: backupURL != nil), session)
        if let backupURL, !Task.isCancelled,
           case .failure(let error, let evidence) = primaryOutcome,
           evidence.provesNeverConnected, Self.isConnectError(error) {
            let backupSession: URLSession
            if backupURL.scheme?.lowercased() == "http" {
                backupSession = session === Self.backgroundSession
                    ? Self.directHTTPBackgroundBackupSession : Self.directHTTPBackupSession
            } else {
                backupSession = session
            }
            try Task.checkCancellation()
            let backupOutcome = await attempt(request(for: backupURL, data: data), backupSession)
            return try Self.finish(backupOutcome, at: backupURL, destination: .backup)
        }
        return try Self.finish(primaryOutcome, at: primary, destination: .primary)
    }

    private func request(for url: URL, data: Data, shortIdleTimeout: Bool = false) -> URLRequest {
        var request = URLRequest(url: url)
        if shortIdleTimeout { request.timeoutInterval = 10 }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let header = authorizationHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data
        return request
    }

    private static func perform(_ request: URLRequest, session: URLSession,
                                startAuthorization: POSTStartAuthorization?) async -> POSTOutcome {
        let delegate = NoRedirectDelegate(recordsPostEvidence: true)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        return await withTaskCancellationHandler {
            let resume: @Sendable () -> Bool = {
                guard !Task.isCancelled else { return false }
                task.resume()
                return true
            }
            // Revocation and resume have a single ordering point. Never await inside the gate.
            let started: Bool
            if let startAuthorization {
                started = startAuthorization.withValidPermission(resume) == true
            } else {
                started = resume()
            }
            guard started else {
                task.cancel()
                return .notStarted
            }
            return await delegate.waitForCompletion()
        } onCancel: {
            task.cancel()
        }
    }

    private static func finish(_ outcome: POSTOutcome, at url: URL, destination: SendReceipt.Destination) throws -> SendReceipt {
        switch outcome {
        case .notStarted:
            throw CancellationError()
        case .response(let body, let response):
            guard let http = response as? HTTPURLResponse else { throw SenderError.unconfirmedDelivery }
            guard (200...299).contains(http.statusCode) else {
                throw SenderError.httpStatus(http.statusCode, body: String(data: body, encoding: .utf8))
            }
            return SendReceipt(destination: destination, host: unbracketedHost(url.host ?? ""))
        case .failure(let error, let evidence):
            if let status = evidence.finalHTTPStatus {
                if (200...299).contains(status) { throw SenderError.interruptedSuccessResponse(status) }
                throw SenderError.httpStatus(status, body: nil)
            }
            let code = (error as? URLError)?.code
            if evidence.provesNeverConnected {
                if Task.isCancelled || error is CancellationError || code == .cancelled { throw CancellationError() }
                if Self.isConnectError(error) { throw error }
            }
            // ATS is a local platform policy denial, not a connection failure or a retry reason.
            if code == .appTransportSecurityRequiresSecureConnection && !evidence.observedHTTP { throw error }
            throw SenderError.unconfirmedDelivery
        }
    }

    private static func isConnectError(_ error: Error) -> Bool {
        switch (error as? URLError)?.code {
        case .timedOut, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .notConnectedToInternet,
             .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return true
        default: return false
        }
    }
}

nonisolated enum POSTOutcome: Sendable {
    case notStarted
    case response(Data, URLResponse)
    case failure(Error, POSTAttemptSummary)
}

/// Raw observations for one POST. Both URLSession and the injectable transport use this aggregation.
nonisolated struct POSTAttemptSummary: Sendable {
    struct Transaction: Sendable {
        var fetchType: URLSessionTaskMetrics.ResourceFetchType = .unknown
        var reusedConnection = false
        var completedConnection = false
        var httpTiming = false
        var requestHeaderBytes: Int64 = 0
        var requestBodyBytes: Int64 = 0
        var responseHeaderBytes: Int64 = 0
        var responseBodyBytes: Int64 = 0
        var response: URLResponse?

        fileprivate var observedHTTP: Bool {
            response != nil || httpTiming || requestHeaderBytes != 0 || requestBodyBytes != 0
                || responseHeaderBytes != 0 || responseBodyBytes != 0
        }
    }

    struct MetricsReport: Sendable {
        var transactions: [Transaction]
        var redirectCount = 0
    }

    var metricsReports: [MetricsReport] = []
    var receivedResponseCallback = false
    var sentBodyProgress = false
    var taskHadResponse = false
    var taskBytesSent: Int64 = 0
    var taskBytesReceived: Int64 = 0

    fileprivate var observedHTTP: Bool {
        receivedResponseCallback || sentBodyProgress || taskHadResponse || taskBytesSent != 0 || taskBytesReceived != 0
            || metricsReports.contains { $0.redirectCount != 0 || $0.transactions.contains(where: \.observedHTTP) }
    }

    fileprivate var finalHTTPStatus: Int? {
        // The task's response and callbacks can refer to an earlier transaction (e.g. a 401
        // before an authentication retry). Only the final transaction can identify its status.
        guard metricsReports.count == 1,
              let response = metricsReports[0].transactions.last?.response as? HTTPURLResponse,
              response.statusCode >= 200 else { return nil }
        return response.statusCode
    }

    fileprivate var provesNeverConnected: Bool {
        guard metricsReports.count == 1, !observedHTTP else { return false }
        let transactions = metricsReports[0].transactions
        return !transactions.isEmpty && transactions.allSatisfy {
            $0.fetchType == .networkLoad && !$0.reusedConnection && !$0.completedConnection
        }
    }
}

private nonisolated func unbracketedHost(_ host: String) -> String {
    if host.first == "[", host.last == "]" { return String(host.dropFirst().dropLast()) }
    return host
}

private nonisolated enum BackupEndpointPolicy {
    static func validatedURL(_ s: String) -> URL? {
        // Validate the original authority as well as Foundation's parsed host. This prevents
        // encoded host/userinfo, zone IDs and lenient parsing of ambiguous numeric addresses.
        guard let delimiter = s.range(of: "://") else { return nil }
        let scheme = s[..<delimiter.lowerBound].lowercased()
        guard scheme == "https" || scheme == "http" else { return nil }
        let authority = s[delimiter.upperBound...].prefix { !"/?#".contains($0) }
        let rawHost: Substring
        let portSuffix: Substring
        let isIPv6 = authority.first == "["
        if isIPv6 {
            guard let closingBracket = authority.firstIndex(of: "]") else { return nil }
            rawHost = authority[authority.index(after: authority.startIndex)..<closingBracket]
            portSuffix = authority[authority.index(after: closingBracket)...]
        } else {
            rawHost = authority.prefix { $0 != ":" }
            portSuffix = authority.dropFirst(rawHost.count)
        }
        if !portSuffix.isEmpty {
            let digits = portSuffix.dropFirst()
            guard portSuffix.first == ":", !digits.isEmpty, digits.utf8.allSatisfy(isDigit),
                  let port = UInt16(digits), port != 0 else { return nil }
        }

        let originalHost = String(rawHost)
        guard !originalHost.isEmpty, let url = URL(string: s), url.user == nil, url.password == nil else { return nil }
        let host: String
        if originalHost.utf8.allSatisfy({ (33...126).contains($0) }) {
            // Keep the existing literal/ASCII path, including already-encoded IDNA labels.
            guard let parsedHost = url.host else { return nil }
            host = unbracketedHost(parsedHost)
            guard host.lowercased() == originalHost.lowercased() else { return nil }
        } else {
            // URL's percent-encoded host accessor can convert A-labels back to escaped Unicode.
            // URLComponents.encodedHost instead retains the ASCII IDNA labels used on the wire.
            guard scheme == "https", !isIPv6,
                  originalHost.utf8.allSatisfy({ $0 >= 128 || isAlphanumeric($0) || $0 == 45 || $0 == 46 }),
                  let asciiHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost,
                  originalHost.filter({ $0 == "." }).count == asciiHost.filter({ $0 == "." }).count,
                  asciiHost.lowercased().split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) else { return nil }
            // Reject numeric address spellings disguised with compatibility characters, even
            // if this version of Foundation encoded those characters rather than mapping them.
            let compatible = originalHost.precomposedStringWithCompatibilityMapping
            guard let last = compatible.split(separator: ".").last, !isNumericAddressSuffix(last) else { return nil }
            host = asciiHost
        }

        let isLocal: Bool
        if isIPv6 {
            var address = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
            isLocal = withUnsafeBytes(of: &address) { bytes in
                (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
            }
        } else {
            var address = in_addr()
            if host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 {
                // Reject leading zeros even on platforms whose inet_pton accepts them.
                guard host.split(separator: ".").allSatisfy({ $0.count == 1 || $0.first != "0" }) else { return nil }
                let bits = UInt32(bigEndian: address.s_addr)
                isLocal = bits >> 24 == 10 || bits >> 20 == 0xac1 || bits >> 16 == 0xc0a8 || bits >> 16 == 0xa9fe
            } else {
                let dns = host.hasSuffix(".") ? host.dropLast() : host[...]
                let labels = dns.split(separator: ".", omittingEmptySubsequences: false)
                guard dns.utf8.count <= 253, labels.allSatisfy(isDNSLabel), let last = labels.last else { return nil }
                // Legacy inet_aton/URL syntaxes can treat numeric or hex-suffixed names as IPs
                // (e.g. 192.168.1, 3232235777, 0300.0250.1.1 or 0xc0a80101).
                guard !isNumericAddressSuffix(last) else { return nil }
                isLocal = labels.count >= 2 && last.lowercased() == "local"
            }
        }
        return scheme == "https" || isLocal ? url : nil
    }

    private static func isDNSLabel(_ label: Substring) -> Bool {
        let bytes = label.utf8
        guard (1...63).contains(bytes.count), let first = bytes.first, let last = bytes.last,
              isAlphanumeric(first), isAlphanumeric(last) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || $0 == 45 }
    }

    private static func isNumericAddressSuffix(_ label: Substring) -> Bool {
        let lower = label.lowercased()
        return lower.utf8.allSatisfy(isDigit) || (lower.hasPrefix("0x") && lower.utf8.dropFirst(2).allSatisfy(isHexDigit))
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
    private static func isHexDigit(_ byte: UInt8) -> Bool { isDigit(byte) || (97...102).contains(byte) }
    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isDigit(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

/// Refuse every redirect and optionally collect per-task evidence before async completion.
nonisolated final class NoRedirectDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private enum Completion: Sendable {
        case pending
        case waiting(CheckedContinuation<POSTOutcome, Never>)
        case finished(POSTOutcome)
    }

    private struct State: Sendable {
        var summary = POSTAttemptSummary()
        var body = Data()
        var completion: Completion = .pending

        mutating func observe(_ task: URLSessionTask) {
            summary.taskHadResponse = summary.taskHadResponse || task.response != nil
            let sent = task.countOfBytesSent
            let received = task.countOfBytesReceived
            if sent != 0 { summary.taskBytesSent = sent }
            if received != 0 { summary.taskBytesReceived = received }
        }
    }

    private let recordsPostEvidence: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(recordsPostEvidence: Bool = false) {
        self.recordsPostEvidence = recordsPostEvidence
        super.init()
    }

    static func shouldFollow(to url: URL?) -> Bool { false }

    fileprivate func waitForCompletion() async -> POSTOutcome {
        await withCheckedContinuation { continuation in
            // A fast response or cancellation may finish before the waiter is installed.
            let finished = state.withLock { state -> POSTOutcome? in
                if case .finished(let outcome) = state.completion { return outcome }
                state.completion = .waiting(continuation)
                return nil
            }
            if let finished { continuation.resume(returning: finished) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if recordsPostEvidence { state.withLock { $0.summary.receivedResponseCallback = true } }
        completionHandler(Self.shouldFollow(to: request.url) ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceiveInformationalResponse response: HTTPURLResponse) {
        if recordsPostEvidence { state.withLock { $0.summary.receivedResponseCallback = true } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if recordsPostEvidence && (bytesSent > 0 || totalBytesSent > 0) {
            state.withLock { $0.summary.sentBodyProgress = true }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if recordsPostEvidence { state.withLock { $0.summary.receivedResponseCallback = true } }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard recordsPostEvidence, !data.isEmpty else { return }
        state.withLock {
            $0.summary.receivedResponseCallback = true
            $0.body.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard recordsPostEvidence else { return }
        let transactions = metrics.transactionMetrics.map { transaction in
            POSTAttemptSummary.Transaction(
                fetchType: transaction.resourceFetchType,
                reusedConnection: transaction.isReusedConnection,
                completedConnection: transaction.connectEndDate != nil || transaction.secureConnectionEndDate != nil,
                httpTiming: transaction.requestStartDate != nil || transaction.requestEndDate != nil
                    || transaction.responseStartDate != nil || transaction.responseEndDate != nil,
                requestHeaderBytes: transaction.countOfRequestHeaderBytesSent,
                requestBodyBytes: transaction.countOfRequestBodyBytesSent,
                responseHeaderBytes: transaction.countOfResponseHeaderBytesReceived,
                responseBodyBytes: transaction.countOfResponseBodyBytesReceived,
                response: transaction.response)
        }
        state.withLock {
            $0.observe(task)
            $0.summary.metricsReports.append(.init(transactions: transactions, redirectCount: metrics.redirectCount))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard recordsPostEvidence else { return }
        let toResume = state.withLock { state -> (CheckedContinuation<POSTOutcome, Never>, POSTOutcome)? in
            if case .finished = state.completion { return nil }
            state.observe(task)
            let outcome: POSTOutcome
            if let error {
                outcome = .failure(error, state.summary)
            } else if let response = task.response {
                outcome = .response(state.body, response)
            } else {
                outcome = .failure(URLError(.badServerResponse), state.summary)
            }
            state.body = Data()
            let previous = state.completion
            state.completion = .finished(outcome)
            if case .waiting(let continuation) = previous { return (continuation, outcome) }
            return nil
        }
        if let (continuation, outcome) = toResume { continuation.resume(returning: outcome) }
    }
}
