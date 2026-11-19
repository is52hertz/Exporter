//
//  SettingsView.swift
//  Exporter
//
//  配置远程 API endpoint 与可选鉴权头。
//

import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Endpoint URL", text: $settings.endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Authorization 头（可选）", text: $settings.authorizationHeader)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("远程 API")
                } footer: {
                    Text("留空则只在本机预览 / 分享，不发送。Authorization 头会原样写入请求，例如 “Bearer 你的令牌”。")
                }

                Section {
                    Toggle("后台增量推送", isOn: $settings.backgroundPushEnabled)
                        .disabled(!settings.hasEndpoint && !settings.backgroundPushEnabled)
                } footer: {
                    Text("开启后，健康数据更新时会将所选且已授权的常规样本自动发送到上方 API。首次推送可能包含历史数据；未配置地址时不会推送。推送时机由系统决定。")
                }

                Section {
                    Stepper(value: $settings.largeExportThresholdDays, in: 1...30) {
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
