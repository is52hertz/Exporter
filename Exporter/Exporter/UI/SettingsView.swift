//
//  SettingsView.swift
//  Exporter
//
//  配置远程 API endpoint 与可选鉴权头。
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var draft: AppSettings.EndpointDraft
    @State private var notificationAuthorization: BackgroundSendNotifications.Authorization?
    @State private var notificationEnableTask: Task<Void, Never>?
    @State private var lastNotificationEnableAttempt: UUID?
    @State private var isEnablingNotifications = false
    @State private var notificationEnableFailed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(settings: AppSettings) {
        self.settings = settings
        draft = settings.endpointDraft
    }

    private var backgroundPushBinding: Binding<Bool> {
        Binding(get: { settings.backgroundPushEnabled }, set: { enabled in
            if !enabled {
                cancelNotificationEnable()
                notificationEnableFailed = false
            }
            settings.setBackgroundPushEnabled(enabled, with: draft)
        })
    }

    private var backgroundNotificationsBinding: Binding<Bool> {
        Binding(get: { isEnablingNotifications || settings.backgroundNotificationMode != .off }, set: { enabled in
            if enabled {
                enableBackgroundNotifications()
            } else {
                cancelNotificationEnable()
                notificationEnableFailed = false
                settings.backgroundNotificationMode = .off
            }
        })
    }

    private var successNotificationsBinding: Binding<Bool> {
        Binding(get: { settings.backgroundNotificationMode == .all }, set: { enabled in
            guard settings.backgroundPushEnabled, notificationAuthorization == .allowed,
                  settings.backgroundNotificationMode != .off else { return }
            settings.backgroundNotificationMode = enabled ? .all : .failures
        })
    }

    private func enableBackgroundNotifications() {
        guard settings.backgroundPushEnabled, notificationEnableTask == nil,
              notificationAuthorization != .denied, settings.backgroundNotificationMode == .off else { return }
        lastNotificationEnableAttempt = UUID()
        notificationEnableFailed = false
        isEnablingNotifications = true
        notificationEnableTask = Task { @MainActor in
            defer {
                isEnablingNotifications = false
                notificationEnableTask = nil
            }

            var authorization = await BackgroundSendNotifications.authorizationStatus()
            var granted = authorization == .allowed
            // A delayed lookup must not prompt after cancellation or after the app leaves the foreground.
            if authorization == .notDetermined, !Task.isCancelled,
               settings.backgroundPushEnabled, UIApplication.shared.applicationState == .active {
                granted = (try? await BackgroundSendNotifications.requestAuthorization()) == true
                authorization = await BackgroundSendNotifications.authorizationStatus()
            }
            notificationAuthorization = authorization
            guard !Task.isCancelled, settings.backgroundPushEnabled,
                  settings.backgroundNotificationMode == .off else { return }

            if granted, authorization == .allowed {
                settings.backgroundNotificationMode = .failures
            } else {
                notificationEnableFailed = authorization != .denied
            }
        }
    }

    private func cancelNotificationEnable() {
        // Keep the task in its slot until it returns: cancellation cannot dismiss an iOS prompt.
        notificationEnableTask?.cancel()
        isEnablingNotifications = false
    }

    private var shouldRefreshNotificationAuthorization: Bool {
        scenePhase == .active && settings.backgroundPushEnabled && notificationEnableTask == nil
    }

    private func refreshNotificationAuthorization() async {
        guard shouldRefreshNotificationAuthorization else { return }
        let attempt = lastNotificationEnableAttempt
        let authorization = await BackgroundSendNotifications.authorizationStatus()
        // A lookup started before a toggle action must not overwrite that action's result.
        guard !Task.isCancelled, settings.backgroundPushEnabled,
              lastNotificationEnableAttempt == attempt else { return }
        notificationAuthorization = authorization
        if authorization == .denied {
            notificationEnableFailed = false
        }
    }

    @ViewBuilder
    private var backgroundNotificationControls: some View {
        let optedIn = settings.backgroundNotificationMode != .off
        Toggle("推送通知", isOn: backgroundNotificationsBinding)
            .disabled(!optedIn && !isEnablingNotifications
                      && (notificationAuthorization == .denied || notificationEnableTask != nil))
            .accessibilityIdentifier("background-notifications")
        if optedIn {
            Toggle("成功时也通知", isOn: successNotificationsBinding)
                .disabled(notificationAuthorization != .allowed)
                .accessibilityIdentifier("background-notifications-success")
        }
        if isEnablingNotifications {
            Text("正在确认通知权限…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if notificationAuthorization == .denied || (optedIn && notificationAuthorization == .notDetermined) {
            Text("系统设置中已关闭通知，无法弹出提醒。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("background-notifications-permission-status")
            Button("去设置") {
                guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                openURL(url)
            }
            .accessibilityIdentifier("background-notifications-open-settings")
        } else if notificationEnableFailed {
            Text("未能开启通知，请重试。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var backupError: LocalizedStringKey? {
        let backupAddress = draft.trimmedBackupEndpoint
        guard !backupAddress.isEmpty else { return nil }
        guard !draft.trimmedEndpoint.isEmpty else { return "请先填写主地址。" }
        guard draft.validatedBackupURL == nil else { return nil }
        if let url = URL(string: backupAddress), url.scheme?.lowercased() == "http", url.host?.isEmpty == false {
            return "http 只能用于局域网地址（如 192.168.x.x 或 .local）。其他地址请用 https://。"
        }
        return "备用地址不完整，请检查地址是否以 https:// 或 http:// 开头。"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("主地址")
                            .font(.subheadline)
                        TextField("主地址", text: $draft.endpoint, prompt: Text("https://…"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("primary-endpoint")
                    }
                    if !draft.trimmedEndpoint.isEmpty, !draft.hasValidPrimaryEndpoint {
                        Text("请输入完整的主地址，以 https:// 开头。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("备用地址（可选）")
                            .font(.subheadline)
                        TextField("备用地址（可选）", text: $draft.backupEndpoint, prompt: Text("https://… 或局域网 http://…"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("backup-endpoint")
                    }
                    if let backupError {
                        Text(backupError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if draft.validatedBackupURL?.scheme?.lowercased() == "http" {
                        Label {
                            Text("这个地址不加密。健康数据和 Authorization 头都可能被同一局域网里的其他设备看到，请只在你信任的网络里使用。")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    TextField("Authorization 头（可选）", text: $draft.authorizationHeader)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("远程 API")
                } footer: {
                    Text("主地址留空时，只在本机预览 / 分享。每次发送都先试主地址，仅在连不上时才改发备用地址。两个地址共用同一个 Authorization 头，例如 “Bearer 你的令牌”。")
                }

                Section {
                    Toggle("后台增量推送", isOn: backgroundPushBinding)
                        .disabled(!settings.backgroundPushEnabled && !settings.canEnableBackgroundPush(with: draft))
                    if settings.backgroundPushEnabled {
                        backgroundNotificationControls
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("开启后，健康数据更新时会自动发送所选且已授权的常规样本。首次推送可能包含历史数据；地址未配置或无效时不会推送。推送时机由系统决定。")
                        if !settings.backgroundPushEnabled && draft != settings.endpointDraft {
                            Text("若要开启推送，请先点「完成」保存地址和鉴权设置，再重新打开设置。")
                        }
                        if settings.backgroundPushEnabled {
                            Text("打开「推送通知」后，连续两批未确认送达时会在本机提醒。打开「成功时也通知」后，成功也会提醒。通知不显示具体地址或健康数值。")
                        }
                    }
                }

                Section {
                    Stepper(value: $settings.largeExportThresholdDays, in: AppSettings.largeExportThresholdRange) {
                        Text("大导出确认阈值：\(settings.largeExportThresholdDays) 天")
                    }
                    Toggle("样本包含 UUID", isOn: $settings.includeUUID)
                } header: {
                    Text("导出")
                } footer: {
                    Text("导出数据跨度超过该天数时，会先弹出确认，可选择继续全部或仅最近 \(settings.largeExportThresholdDays) 天。UUID 用于接收端精确去重，会显著增大文件。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        cancelNotificationEnable()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        if settings.applyEndpointDraft(draft) {
                            cancelNotificationEnable()
                            dismiss()
                        }
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
        .task(id: shouldRefreshNotificationAuthorization) { await refreshNotificationAuthorization() }
        .onChange(of: settings.backgroundPushEnabled) { _, enabled in
            if !enabled {
                cancelNotificationEnable()
                notificationEnableFailed = false
            }
        }
        .onDisappear { cancelNotificationEnable() }
    }
}
