import HealthKit
import Observation
import OSLog
import UIKit

@MainActor
final class BackgroundDelivery {
    private let settings: AppSettings
    private let health: HealthKitManager
    private let defaults = UserDefaults.standard
    private let registrationKey = "backgroundDelivery.metrics"
    private let logger = Logger(subsystem: "cn.Teethe.Exporter", category: "BackgroundDelivery")
    private var observers: [HealthMetric: HKObserverQuery] = [:]
    private var configuration: BackgroundPush.Configuration?
    private var registrations = Set<HealthMetric>()
    private var enabledThisLaunch = Set<HealthMetric>()
    private var registrationWorker: Task<Void, Never>?
    private var registrationsChanged = false

    private lazy var push = BackgroundPush(
        configuration: { [weak self] in self?.currentConfiguration() },
        fetch: { [health] metrics in
            try await health.fetch(metrics: metrics, mode: .incremental, start: nil, end: nil, background: true)
        },
        sender: { config in BackgroundDelivery.makeSender(config) },
        commit: { [health] outcome in health.commit(outcome, background: true) },
        device: .init(model: UIDevice.current.model,
                      os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"))

    /// 后台推送走和手动发送同一个发送器（HTTPSender：只发 https、拒绝一切重定向），
    /// 会话用全进程共用的 HTTPSender.backgroundSession。
    nonisolated static func makeSender(_ config: BackgroundPush.Configuration) -> HTTPSender {
        HTTPSender(endpoint: config.endpoint, authorizationHeader: config.authorizationHeader,
                   session: HTTPSender.backgroundSession)
    }

    init(settings: AppSettings, health: HealthKitManager) {
        self.settings = settings
        self.health = health
        registrations = Set((defaults.stringArray(forKey: registrationKey) ?? []).compactMap(HealthMetric.init(rawValue:)))
    }

    func start() {
        guard health.isHealthDataAvailable else { return }
        applySettings()
    }

    private func currentConfiguration() -> BackgroundPush.Configuration? {
        guard settings.backgroundPushEnabled else { return nil }
        let endpoint = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        let metrics = HealthMetric.registered.filter {
            settings.selectedMetrics.contains($0) && HealthKitManager.supportsBackgroundPush($0)
        }
        guard !metrics.isEmpty else { return nil }
        return .init(metrics: metrics, endpoint: endpoint, authorizationHeader: settings.authorizationHeader,
                     includeUUID: settings.includeUUID)
    }

    private func applySettings() {
        let updated = withObservationTracking {
            // Reconcile again after the user completes the authorization flow.
            _ = settings.hasRequestedAuthorization
            return currentConfiguration()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.applySettings() }
        }

        if configuration != updated, configuration != nil { push.cancel() }
        configuration = updated
        let desired = Set(updated?.metrics ?? [])
        for metric in Set(observers.keys).subtracting(desired) {
            if let query = observers.removeValue(forKey: metric) { health.stopObserving(query) }
        }
        for metric in desired where observers[metric] == nil {
            observers[metric] = health.observe(metric) { [weak self] query, completion in
                guard let self, self.observers[metric] === query else {
                    completion()
                    return
                }
                self.push.notify(completion: completion)
            }
        }

        registrationsChanged = true
        if registrationWorker == nil {
            registrationWorker = Task { await reconcileRegistrations() }
        }
    }

    private func reconcileRegistrations() async {
        defer { registrationWorker = nil }
        while registrationsChanged {
            registrationsChanged = false
            let desired = Set(observers.keys)
            for metric in registrations.subtracting(desired) {
                if registrationsChanged { break }
                enabledThisLaunch.remove(metric)
                do {
                    try await health.setBackgroundDelivery(false, for: metric)
                    registrations.remove(metric)
                    persistRegistrations()
                } catch {
                    logger.error("Could not disable HealthKit background delivery.")
                }
            }
            for metric in desired.subtracting(enabledThisLaunch) {
                if registrationsChanged { break }
                registrations.insert(metric)
                persistRegistrations()
                do {
                    try await health.setBackgroundDelivery(true, for: metric)
                    enabledThisLaunch.insert(metric)
                } catch {
                    logger.debug("HealthKit background delivery registration was unavailable for a sample type.")
                }
            }
        }
    }

    private func persistRegistrations() {
        defaults.set(registrations.map(\.rawValue), forKey: registrationKey)
    }
}
