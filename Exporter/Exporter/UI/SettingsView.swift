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
