import Foundation

/// 首页只保留一条发送结果，不保存地址、凭据、负载或服务端文本。
nonisolated struct SendAttempt: Codable, Equatable, Sendable {
    enum Outcome: Codable, Equatable, Sendable {
        case success(sampleCount: Int, destination: SendReceipt.Destination)
        case deliveryUnconfirmed
        case failure(httpStatus: Int?)

        /// 无实际 POST 的取消或配置错误不替换上一次发送结果。
        init?(sendError error: Error) {
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return nil }
            switch error as? SenderError {
            case .missingEndpoint?, .invalidURL(_)?, .insecureScheme(_)?, .invalidBackupEndpoint?:
                return nil
            case .unconfirmedDelivery?, .interruptedSuccessResponse(_)?:
                self = .deliveryUnconfirmed
            case .httpStatus(let code, _)?:
                self = .failure(httpStatus: code)
            default:
                self = .failure(httpStatus: nil)
            }
        }
    }

    let date: Date
    let origin: SendReceipt.Origin
    let outcome: Outcome

    /// 不从当前设置或不匹配的旧回执推断这次发送的主机。
    func confirmedHost(from receipt: SendReceipt?) -> String? {
        guard case .success(_, let destination) = outcome,
              let receipt, receipt.confirmedAt == date, receipt.origin == origin,
              receipt.destination == destination, !receipt.host.isEmpty else { return nil }
        return receipt.host
    }
}
