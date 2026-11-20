import Foundation
import OSLog

@MainActor
final class BackgroundPush {
    nonisolated struct Configuration: Equatable, Sendable {
        let metrics: [HealthMetric]
        let endpoint: String
        let authorizationHeader: String
        let includeUUID: Bool
    }

    private let configuration: () -> Configuration?
    private let fetch: ([HealthMetric]) async throws -> HealthKitManager.FetchOutcome
    private let sender: (Configuration) -> any ExportSender
    private let commit: (HealthKitManager.FetchOutcome) -> Void
    private let device: ExportDocument.DeviceInfo
    private let batchingDelay: Duration
    private let logger = Logger(subsystem: "cn.Teethe.Exporter", category: "BackgroundPush")
    private var pending: [() -> Void] = []
    private var worker: Task<Void, Never>?

    init(configuration: @escaping () -> Configuration?,
         fetch: @escaping ([HealthMetric]) async throws -> HealthKitManager.FetchOutcome,
         sender: @escaping (Configuration) -> any ExportSender,
         commit: @escaping (HealthKitManager.FetchOutcome) -> Void,
         device: ExportDocument.DeviceInfo,
         batchingDelay: Duration = .seconds(2)) {
        self.configuration = configuration
        self.fetch = fetch
        self.sender = sender
        self.commit = commit
        self.device = device
        self.batchingDelay = batchingDelay
    }

    @discardableResult
    func notify(completion: @escaping () -> Void) -> Task<Void, Never>? {
        guard configuration() != nil else {
            completion()
            return nil
        }
        pending.append(completion)
        if worker == nil {
            worker = Task { await drain() }
        }
        return worker
    }

    func cancel() {
        worker?.cancel()
        completePending()
    }

    private func drain() async {
        defer {
            worker = nil
            // A new opt-in may enqueue notifications while a cancelled fetch is unwinding.
            if !pending.isEmpty { worker = Task { await drain() } }
        }
        while !pending.isEmpty && !Task.isCancelled {
            do {
                try await Task.sleep(for: batchingDelay)
            } catch {
                return
            }
            let batch = pending
            pending.removeAll()
            await push()
            batch.forEach { $0() }
        }
    }

    private func completePending() {
        let batch = pending
        pending.removeAll()
        batch.forEach { $0() }
    }

    private func push() async {
        guard let config = configuration(), !Task.isCancelled else { return }
        do {
            let outcome = try await fetch(config.metrics)
            guard !outcome.samples.isEmpty else { return }
            let device = self.device
            let data = await Task.detached(priority: .utility) {
                JSONExporter.encode(ExportDocument(
                    samples: outcome.samples, device: device,
                    range: .init(mode: .incremental, start: nil, end: nil),
                    includeUUID: config.includeUUID))
            }.value
            guard !Task.isCancelled, configuration() == config else { return }
            try await sender(config).send(data)
            guard !Task.isCancelled, configuration() == config else { return }
            commit(outcome)
        } catch {
            if !Task.isCancelled { logger.error("Background push failed; anchors were not advanced.") }
        }
    }
}
