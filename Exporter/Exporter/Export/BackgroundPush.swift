import Foundation
import Observation
import OSLog

@MainActor
final class BackgroundPush {
    nonisolated struct Configuration: Equatable, Sendable {
        let metrics: [HealthMetric]
        let endpoint: String
        let backupEndpoint: String
        let authorizationHeader: String
        let includeUUID: Bool
    }

    nonisolated enum ResultNotice: Equatable, Sendable {
        case success(sampleCount: Int, destination: SendReceipt.Destination)
        case notConfirmed
    }

    private let configuration: () -> Configuration?
    private let fetch: ([HealthMetric]) async throws -> HealthKitManager.FetchOutcome
    private let sender: (Configuration, POSTStartAuthorization) -> any ExportSender
    private let commit: (HealthKitManager.FetchOutcome, SendReceipt) -> Void
    // Persist the completed send independently of local notification settings or awaits.
    private let recordAttempt: (SendAttempt) -> Void
    private let report: (ResultNotice) async -> Void
    private let device: ExportDocument.DeviceInfo
    private let batchingDelay: Duration
    private let logger = Logger(subsystem: "cn.Teethe.Exporter", category: "BackgroundPush")
    private var pending: [() -> Void] = []
    private var worker: Task<Void, Never>?
    private var activeStartAuthorization: POSTStartAuthorization?

    init(configuration: @escaping () -> Configuration?,
         fetch: @escaping ([HealthMetric]) async throws -> HealthKitManager.FetchOutcome,
         sender: @escaping (Configuration, POSTStartAuthorization) -> any ExportSender,
         commit: @escaping (HealthKitManager.FetchOutcome, SendReceipt) -> Void,
         recordAttempt: @escaping (SendAttempt) -> Void = { _ in },
         report: @escaping (ResultNotice) async -> Void = { _ in },
         device: ExportDocument.DeviceInfo,
         batchingDelay: Duration = .seconds(2)) {
        self.configuration = configuration
        self.fetch = fetch
        self.sender = sender
        self.commit = commit
        self.recordAttempt = recordAttempt
        self.report = report
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

    /// The tracked settings are MainActor-only. Observation calls back synchronously before
    /// the setting changes. Revoke transport permission here, not in a queued actor job.
    func trackConfiguration(_ read: () -> Configuration?,
                            onChange: @escaping @MainActor @Sendable () -> Void = {}) -> Configuration? {
        withObservationTracking(read, onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.revokeActiveStart()
                onChange()
            }
        })
    }

    private func revokeActiveStart() {
        activeStartAuthorization?.invalidate()
        activeStartAuthorization = nil
    }

    func cancel() {
        revokeActiveStart()
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
            // Give the report its scheduling attempt before completing the HealthKit wakes.
            await push()
            batch.forEach { $0() }
        }
    }

    private func completePending() {
        let batch = pending
        pending.removeAll()
        batch.forEach { $0() }
    }

    private func isCurrent(_ config: Configuration, _ startAuthorization: POSTStartAuthorization) -> Bool {
        !Task.isCancelled && activeStartAuthorization === startAuthorization && configuration() == config
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func push() async {
        guard let config = configuration(), !Task.isCancelled else { return }
        let startAuthorization = POSTStartAuthorization()
        activeStartAuthorization = startAuthorization
        defer { activeStartAuthorization = nil }

        let outcome: HealthKitManager.FetchOutcome
        do {
            outcome = try await fetch(config.metrics)
        } catch {
            if isCurrent(config, startAuthorization), !isCancellation(error) {
                logger.error("Background push could not fetch samples; anchors were not advanced.")
            }
            return
        }
        guard !outcome.samples.isEmpty, isCurrent(config, startAuthorization) else { return }

        let device = self.device
        let data = await Task.detached(priority: .utility) {
            JSONExporter.encode(ExportDocument(
                samples: outcome.samples, device: device,
                range: .init(mode: .incremental, start: nil, end: nil),
                includeUUID: config.includeUUID))
        }.value
        guard isCurrent(config, startAuthorization) else { return }

        let receipt: SendReceipt
        do {
            receipt = try await sender(config, startAuthorization).send(data)
        } catch {
            guard isCurrent(config, startAuthorization), !isCancellation(error) else { return }
            if let outcome = SendAttempt.Outcome(sendError: error) {
                recordAttempt(SendAttempt(date: Date(), origin: .background, outcome: outcome))
            }
            logger.error("Background push delivery was not confirmed; anchors were not advanced.")
            await report(.notConfirmed)
            return
        }
        guard isCurrent(config, startAuthorization) else { return }
        let date = Date()
        commit(outcome, receipt.dated(at: date, origin: .background))
        guard isCurrent(config, startAuthorization) else { return }
        recordAttempt(SendAttempt(date: date, origin: .background,
                                  outcome: .success(sampleCount: outcome.samples.count, destination: receipt.destination)))
        await report(.success(sampleCount: outcome.samples.count, destination: receipt.destination))
    }
}
