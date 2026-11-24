import HealthKit
import OSLog
import UIKit

@MainActor
final class BackgroundDelivery {
    private let settings: AppSettings
    private let health: HealthKitManager
    private let notifications: BackgroundSendNotifications
    private let defaults = UserDefaults.standard
    private let registrationKey = "backgroundDelivery.metrics"
    private let logger = Logger(subsystem: "cn.Teethe.Exporter", category: "BackgroundDelivery")
    private var observers: [HealthMetric: HKObserverQuery] = [:]
    private var configuration: BackgroundPush.Configuration?
    private var configurationNeedsRefresh = false
    private var registrations = Set<HealthMetric>()
    private var enabledThisLaunch = Set<HealthMetric>()
    private var registrationWorker: Task<Void, Never>?
    private var registrationsChanged = false

    private lazy var push = BackgroundPush(
        configuration: { [weak self] in
            guard let self, !self.configurationNeedsRefresh else { return nil }
            return self.configuration
        },
        fetch: { [health] metrics in
            try await health.fetch(metrics: metrics, mode: .incremental, start: nil, end: nil, background: true)
        },
        sender: { config, startAuthorization in BackgroundDelivery.makeSender(config, startAuthorization: startAuthorization) },
        commit: { [health, settings] outcome, receipt in
            health.commit(outcome, background: true)
            settings.lastSendReceipt = receipt.dated(at: Date(), origin: .background)
        },
        report: { [notifications] result in await notifications.report(result) },
        device: .init(model: UIDevice.current.model,
                      os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"))

    /// 后台推送与手动发送共用 HTTPSender 的地址校验、备用地址逻辑及重定向限制。
    /// 后台使用全进程共用的 HTTPSender.backgroundSession。
    nonisolated static func makeSender(_ config: BackgroundPush.Configuration,
                                       startAuthorization: POSTStartAuthorization? = nil) -> HTTPSender {
        HTTPSender(endpoint: config.endpoint, backupEndpoint: config.backupEndpoint,
                   authorizationHeader: config.authorizationHeader, session: HTTPSender.backgroundSession,
                   startAuthorization: startAuthorization)
    }

    init(settings: AppSettings, health: HealthKitManager) {
        self.settings = settings
        self.health = health
        self.notifications = BackgroundSendNotifications(settings: settings)
        registrations = Set((defaults.stringArray(forKey: registrationKey) ?? []).compactMap(HealthMetric.init(rawValue:)))
    }

    func start() {
        guard health.isHealthDataAvailable else { return }
        applySettings()
    }

    func currentConfiguration() -> BackgroundPush.Configuration? {
        guard settings.backgroundPushEnabled else { return nil }
        let endpoint = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let backupEndpoint = settings.backupEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HTTPSender.validatedURL(endpoint) != nil,
              backupEndpoint.isEmpty || HTTPSender.validatedBackupURL(backupEndpoint) != nil else { return nil }
        let metrics = HealthMetric.registered.filter {
            settings.selectedMetrics.contains($0) && HealthKitManager.supportsBackgroundPush($0)
        }
        guard !metrics.isEmpty else { return nil }
        return .init(metrics: metrics, endpoint: endpoint, backupEndpoint: backupEndpoint,
                     authorizationHeader: settings.authorizationHeader, includeUUID: settings.includeUUID)
    }

    private func applySettings() {
        let updated = push.trackConfiguration {
            // Reconcile again after the user completes the authorization flow.
            _ = settings.hasRequestedAuthorization
            return currentConfiguration()
        } onChange: { [weak self] in
            // Transport permission is already revoked. Refresh after the setting is written.
            self?.configurationNeedsRefresh = true
            Task { @MainActor [weak self] in self?.refreshSettingsIfNeeded() }
        }

        if configuration != nil, configurationNeedsRefresh || configuration != updated { push.cancel() }
        configuration = updated
        configurationNeedsRefresh = false
        let desired = Set(updated?.metrics ?? [])
        for metric in Set(observers.keys).subtracting(desired) {
            if let query = observers.removeValue(forKey: metric) { health.stopObserving(query) }
        }
        for metric in desired where observers[metric] == nil {
            observers[metric] = health.observe(metric) { [weak self] query, completion in
                // A wake can already be queued ahead of the deferred settings refresh. Evaluate
                // it with the saved replacement, not the revoked snapshot.
                self?.refreshSettingsIfNeeded()
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

    private func refreshSettingsIfNeeded() {
        if configurationNeedsRefresh { applySettings() }
    }

    private func reconcileRegistrations() async {
        defer { registrationWorker = nil }
        while registrationsChanged {
            registrationsChanged = false
            let desired = Set(observers.keys)
            for metric in registrations.subtracting(desired) {
                if registrationsChanged || configurationNeedsRefresh { break }
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
                if registrationsChanged || configurationNeedsRefresh { break }
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
