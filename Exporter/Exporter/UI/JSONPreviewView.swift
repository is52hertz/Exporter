//
//  JSONPreviewView.swift
//  Exporter
//
//  导出结果预览：摘要卡 + 截断的 JSON 片段。
//  完整 JSON 已落盘临时文件，经 ShareLink 分享文件或发送到 API；
//  不在 Text 中渲染完整大字符串，避免主线程布局卡死。
//

import SwiftUI

struct JSONPreviewView: View {
    @Bindable var model: ExportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    snippetSection
                }
                .padding()
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
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let fileURL = model.exportFileURL {
                        ShareLink(item: fileURL) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
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

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
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
