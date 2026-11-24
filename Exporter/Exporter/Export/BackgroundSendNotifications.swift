import Foundation
import OSLog
import UserNotifications

/// Reporting does not affect sends, anchors, or their receipts. No remote notification registration.
@MainActor
final class BackgroundSendNotifications {
    enum Authorization: Equatable { case notDetermined, allowed, denied }

    nonisolated static let successIdentifier = "push-success"
    nonisolated static let failureIdentifier = "push-failure"

    private typealias Kind = AppSettings.BackgroundNoticeKind
    private nonisolated static let revisionKey = "noticeRevision"

    private let settings: AppSettings
    private let authorization: @MainActor () async -> Authorization
    private let schedule: @MainActor (UNNotificationRequest) async throws -> Void
    private let removeNotice: @MainActor (String) -> Void
    private var inFlightAdds: [Kind: [CheckedContinuation<Void, Never>]] = [:]
    private let logger = Logger(subsystem: "cn.Teethe.Exporter", category: "BackgroundSendNotifications")

    init(settings: AppSettings,
         authorization: @escaping @MainActor () async -> Authorization = { await BackgroundSendNotifications.authorizationStatus() },
         schedule: @escaping @MainActor (UNNotificationRequest) async throws -> Void = { request in
             try await UNUserNotificationCenter.current().add(request)
         },
         removeNotice: @escaping @MainActor (String) -> Void = { identifier in
             let center = UNUserNotificationCenter.current()
             center.removePendingNotificationRequests(withIdentifiers: [identifier])
             center.removeDeliveredNotifications(withIdentifiers: [identifier])
         }) {
        self.settings = settings
        self.authorization = authorization
        self.schedule = schedule
        self.removeNotice = removeNotice
        settings.onBackgroundNoticeRevoked = { kind in
            removeNotice(BackgroundSendNotifications.identifier(for: kind))
        }
    }

    static func authorizationStatus() async -> Authorization {
        let state = await UNUserNotificationCenter.current().notificationSettings()
        switch state.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional, .ephemeral:
            return state.alertSetting == .enabled || state.notificationCenterSetting == .enabled || state.lockScreenSetting == .enabled
                ? .allowed : .denied
        default: return .denied
        }
    }

    static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func report(_ result: BackgroundPush.ResultNotice) async {
        guard settings.backgroundPushEnabled, !Task.isCancelled else { return }
        let kind: Kind
        switch result {
        case .success:
            settings.clearBackgroundFailures()
            kind = .success
        case .notConfirmed:
            guard settings.backgroundNotificationMode != .off,
                  settings.recordUnconfirmedBackgroundSend() else { return }
            kind = .failure
        }

        guard let revision = settings.backgroundNoticeRevision(for: kind),
              await authorization() == .allowed, isCurrent(revision, for: kind) else { return }
        // Fixed IDs require an obsolete add to finish (and be removed) before a
        // replacement of that kind can be added. Recovery itself never waits here.
        while inFlightAdds[kind] != nil {
            await withCheckedContinuation { inFlightAdds[kind, default: []].append($0) }
            guard isCurrent(revision, for: kind) else { return }
        }
        guard kind != .failure || settings.backgroundFailureNoticeIsEligible else { return }
        inFlightAdds[kind] = []
        defer { inFlightAdds.removeValue(forKey: kind)?.forEach { $0.resume() } }

        let request = Self.request(for: result, kind: kind, revision: revision)
        do {
            try await schedule(request)
            // The synchronous removal may have happened before iOS finished an in-flight add.
            // Withdraw again, before releasing the fixed identifier for a new add.
            if settings.backgroundNoticeRevision(for: kind) != revision {
                removeNotice(request.identifier)
            } else if Task.isCancelled {
                settings.revokeBackgroundNotices([kind])
            } else if kind == .failure {
                settings.markBackgroundFailureNoticeScheduled()
            }
        } catch {
            // Do not include the system error, which can carry request details.
            logger.error("Could not schedule the local background send notification.")
        }
    }

    private func isCurrent(_ revision: String, for kind: Kind) -> Bool {
        !Task.isCancelled && settings.backgroundNoticeRevision(for: kind) == revision
    }

    private static func identifier(for kind: Kind) -> String {
        switch kind {
        case .success: successIdentifier
        case .failure: failureIdentifier
        }
    }

    nonisolated static func revision(in request: UNNotificationRequest) -> String? {
        request.content.userInfo[revisionKey] as? String
    }

    static func presentationOptions(for identifier: String, revision: String?,
                                    settings: AppSettings) -> UNNotificationPresentationOptions {
        guard let revision else { return [] }
        switch identifier {
        case successIdentifier where settings.backgroundNoticeRevision(for: .success) == revision:
            return [.list]
        case failureIdentifier where settings.backgroundNoticeRevision(for: .failure) == revision:
            return [.banner, .list, .sound]
        default:
            return []
        }
    }

    private static func request(for result: BackgroundPush.ResultNotice, kind: Kind, revision: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = "exporter.push"
        content.userInfo = [revisionKey: revision]
        switch result {
        case .success(let count, let destination):
            content.interruptionLevel = .passive
            content.title = String(localized: "后台推送完成")
            switch destination {
            case .primary:
                content.body = String(localized: "已发送 \(count) 条样本 · 主地址")
            case .backup:
                content.body = String(localized: "已发送 \(count) 条样本 · 备用地址")
            }
        case .notConfirmed:
            content.interruptionLevel = .active
            content.sound = .default
            content.title = String(localized: "后台推送未确认送达")
            content.body = String(localized: "连续两次推送未确认送达。请先到接收端查看。")
        }
        // Immediate, one identifier per result kind. Metadata is only an opaque generation.
        return UNNotificationRequest(identifier: identifier(for: kind), content: content, trigger: nil)
    }
}
