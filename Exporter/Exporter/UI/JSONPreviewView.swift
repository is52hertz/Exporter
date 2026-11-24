//
//  JSONPreviewView.swift
//  Exporter
//
//  导出结果预览：摘要卡 + 截断的 JSON 片段。
//  完整 JSON 已落盘临时文件，经 ShareLink 分享文件或发送到 API；
//  不在 Text 中渲染完整大字符串，避免主线程布局卡死。
//

import Accessibility
import SwiftUI

struct JSONPreviewView: View {
    @Bindable var model: ExportModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    snippetSection
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    sendFeedback
                    // 系统工具栏高度受限；辅助字号使用不会压缩文字的同一按钮。
                    if dynamicTypeSize.isAccessibilitySize {
                        sendButton
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                    }
                }
                .background(.background)
            }
            .navigationTitle("\(model.sampleCount) 条样本")
            .navigationBarTitleDisplayMode(.inline)
            .alert("发送提示", isPresented: errorPresented) {
                Button("好", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { model.showPreview = false }
                        .accessibilityIdentifier("preview.closeButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let fileURL = model.exportFileURL {
                        ShareLink(item: fileURL) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize {
                    ToolbarItem(placement: .bottomBar) {
                        sendButton
                    }
                }
            }
        }
        .sensoryFeedback(trigger: model.manualSendOutcome?.id) { _, current in
            guard let outcome = visibleOutcome(id: current) else { return nil }
            switch outcome.result {
            case .success: return .success
            case .deliveryUnconfirmed: return .warning
            case .failure: return .error
            }
        }
        .onChange(of: model.manualSendOutcome?.id) { _, current in
            guard let outcome = visibleOutcome(id: current), case .success = outcome.result else { return }
            var message = feedback(for: outcome.result).message
            message.locale = locale
            AccessibilityNotification.Announcement(String(localized: message)).post()
        }
    }

    private var sendButton: some View {
        Button {
            Task { await model.send() }
        } label: {
            Group {
                if model.isSending {
                    HStack(spacing: 8) {
                        ProgressView()
                            .accessibilityHidden(true)
                        Text("正在发送…")
                    }
                } else {
                    Label("发送到 API", systemImage: "paperplane.fill")
                }
            }
            .labelStyle(.titleAndIcon)
            .lineLimit(nil)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .disabled(!model.settings.hasEndpoint || model.isWorking)
        .accessibilityIdentifier("preview.sendButton")
    }

    @ViewBuilder
    private var sendFeedback: some View {
        if let outcome = model.manualSendOutcome {
            let feedback = feedback(for: outcome.result)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: feedback.symbol)
                    .foregroundStyle(feedback.color)
                    .accessibilityHidden(true)
                Text(feedback.message)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(feedback.identifier)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private struct Feedback {
        let message: LocalizedStringResource
        let symbol: String
        let color: Color
        let identifier: String
    }

    private func feedback(for result: ExportModel.ManualSendOutcome.Result) -> Feedback {
        switch result {
        case .success(let count, let destination):
            let message: LocalizedStringResource = switch destination {
            case .primary: "已发送 \(count) 条 · 主地址"
            case .backup: "已发送 \(count) 条 · 备用地址"
            }
            return Feedback(message: message, symbol: "checkmark.circle.fill", color: .green,
                            identifier: "preview.sendSuccess")
        case .deliveryUnconfirmed:
            return Feedback(message: "发送结果未确认 · 再发可能重复", symbol: "exclamationmark.triangle.fill", color: .orange,
                            identifier: "preview.sendUnconfirmed")
        case .failure:
            return Feedback(message: "发送失败", symbol: "xmark.circle.fill", color: .red,
                            identifier: "preview.sendFailure")
        }
    }

    private func visibleOutcome(id: UUID?) -> ExportModel.ManualSendOutcome? {
        guard model.showPreview, scenePhase == .active,
              let outcome = model.manualSendOutcome, outcome.id == id else { return nil }
        return outcome
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.showPreview && model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    // MARK: 摘要

    private var summaryCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("文件大小",
                               value: model.exportByteCount.formatted(.byteCount(style: .file)))
                if let start = model.dataStart, let end = model.dataEnd {
                    LabeledContent("数据范围", value: rangeText(start: start, end: end))
                }
                ForEach(model.metricCounts) { item in
                    LabeledContent(item.displayName, value: "\(item.count) 条")
                }
            }
            .font(.subheadline)
        } label: {
            Label("导出摘要", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func rangeText(start: Date, end: Date) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }

    // MARK: JSON 片段

    private var snippetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.previewSnippet)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.previewTruncated {
                Label("预览已截断，完整内容请通过分享导出文件查看。", systemImage: "scissors")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
