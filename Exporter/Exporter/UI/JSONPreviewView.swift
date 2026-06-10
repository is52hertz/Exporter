//
//  JSONPreviewView.swift
//  Exporter
//
//  JSON 预览：等宽展示、可选中、可通过 ShareLink 导出，或发送到 API。
//

import SwiftUI

struct JSONPreviewView: View {
    @Bindable var model: ExportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(model.jsonString)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("\(model.samples.count) 条样本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: model.jsonString) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        Task { await model.send() }
                    } label: {
                        Label("发送到 API", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!model.settings.hasEndpoint || model.isWorking)
                }
            }
        }
    }
}
