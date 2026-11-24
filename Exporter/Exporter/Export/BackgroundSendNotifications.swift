import Foundation
import OSLog
import UserNotifications

/// Reporting does not affect sends, anchors, or their receipts. No remote notification registration.
@MainActor
final class BackgroundSendNotifications {
    enum Authorization: Equatable { case notDetermined, allowed, denied }

    nonisolated static let successIdentifier = "push-success"
    nonisolated static let failureIdentifier = "push-failure"

    private let settings: AppSettings
    private let authorization: () async -> Authorization
    private let schedule: (UNNotificationRequest) async throws -> Void
    private let removeNotice: @MainActor (String) -> Void
    private let logger = Logger(subsystem: "cn.Teethe.Exporter", category: "BackgroundSendNotifications")

    init(settings: AppSettings,
         authorization: @escaping () async -> Authorization = { await BackgroundSendNotifications.authorizationStatus() },
         schedule: @escaping (UNNotificationRequest) async throws -> Void = { request in
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
        let mode = settings.backgroundNotificationMode
        let revision = settings.backgroundNotificationRevision
        let successRevision: UUID?
        switch result {
        case .success:
            settings.clearBackgroundFailures()
            removeNotice(Self.failureIdentifier)
            guard mode == .all else { return }
            successRevision = settings.successNotificationRevision
        case .notConfirmed:
            guard mode != .off, settings.recordUnconfirmedBackgroundSend() else { return }
            successRevision = nil
        }

        guard await authorization() == .allowed, isCurrent(revision, successRevision: successRevision) else { return }
        let request = Self.request(for: result)
        do {
            try await schedule(request)
            // An immediate notice handed to iOS may already have appeared. Withdraw any
            // remaining copy if the user revoked permission in-app while add was in flight.
            guard isCurrent(revision, successRevision: successRevision) else {
                removeNotice(request.identifier)
                return
            }
            if case .notConfirmed = result { settings.markBackgroundFailureNoticeScheduled() }
        } catch {
            // Do not include the system error, which can carry request details.
            logger.error("Could not schedule the local background send notification.")
        }
    }

    private func isCurrent(_ revision: UUID, successRevision: UUID?) -> Bool {
        !Task.isCancelled && settings.backgroundNotificationRevision == revision
            && (successRevision == nil || successRevision == settings.successNotificationRevision)
    }

    private static func request(for result: BackgroundPush.ResultNotice) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = "exporter.push"
        let identifier: String
        switch result {
        case .success(let count, let destination):
            identifier = successIdentifier
            content.interruptionLevel = .passive
            content.title = String(localized: "后台推送完成")
            switch destination {
            case .primary:
                content.body = String(localized: "已发送 \(count) 条样本 · 主地址")
            case .backup:
                content.body = String(localized: "已发送 \(count) 条样本 · 备用地址")
            }
        case .notConfirmed:
            identifier = failureIdentifier
            content.interruptionLevel = .active
            content.sound = .default
            content.title = String(localized: "后台推送未确认送达")
            content.body = String(localized: "连续两次推送未确认送达。请先到接收端查看。")
        }
        // Immediate, one identifier per result kind. No URLs, payload, or errors.
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}
