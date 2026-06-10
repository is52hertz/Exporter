//
//  ContentView.swift
//  Exporter
//
//  主界面：授权 → 选择模式与指标 → 读取并预览 / 发送。
//  采用原生 SwiftUI 组件，自动获得 iOS 26 Liquid Glass 外观。
//

import SwiftUI

struct ContentView: View {
    @State private var model = ExportModel()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Form {
                authSection
                modeSection
                metricsSection
                actionSection
            }
            .navigationTitle("健康数据导出")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
            }
            .task {
                await model.refreshAuthorizationState()
                await model.refreshProbes()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: model.settings)
            }
            .sheet(isPresented: $model.showPreview) {
                JSONPreviewView(model: model)
            }
            .alert("出错了", isPresented: errorPresented) {
                Button("好", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert("管理健康权限", isPresented: $model.showAuthSettingsAlert) {
                Button("去设置") { model.openSystemSettings() }
                Button("好", role: .cancel) {}
            } message: {
                Text("授权面板只能由系统首次弹出。如需更改读取权限，请在「设置 → 隐私与安全性 → 健康」或「健康 App → 共享」中调整。")
            }
            .disabled(model.isWorking)
            .overlay {
                if model.isWorking {
                    ProgressView().controlSize(.large)
                }
            }
            .overlay {
                confirmOverlay
            }
        }
    }

    // MARK: Sections

    private var authSection: some View {
        Section {
            Button {
                Task { await model.handleAuthorizationTap() }
            } label: {
                Label(model.authorizationDetermined ? "健康权限已设置（点此管理）" : "请求健康数据授权",
                      systemImage: "heart.text.square")
            }
        } footer: {
            Text("仅读取你授权的数据。HealthKit 不会告知 App 你“拒绝”了哪些项；下方各指标显示的是探测到的最近数据。")
        }
    }

    private var modeSection: some View {
        Section {
            Picker("模式", selection: modeBinding) {
                ForEach(SyncMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if model.settings.mode == .range {
                DatePicker("开始", selection: rangeStartBinding,
                           in: ...model.settings.rangeEnd, displayedComponents: [.date, .hourAndMinute])
                DatePicker("结束", selection: rangeEndBinding,
                           in: model.settings.rangeStart..., displayedComponents: [.date, .hourAndMinute])
            }
        } header: {
            Text("时间范围")
        } footer: {
            if model.settings.mode == .incremental {
                Text(incrementalSyncText)
            }
        }
    }

    private var metricsSection: some View {
        Section("数据指标") {
            ForEach(HealthMetric.registered) { metric in
                Toggle(isOn: binding(for: metric)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.displayName)
                            Text(subtitle(for: metric))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: metric.systemImage)
                    }
                }
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                model.startExport()
            } label: {
                Label("读取并预览 JSON", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(!model.canRead)
        } footer: {
            if let status = model.statusMessage {
                Text(status)
            }
        }
    }

    // MARK: 大导出确认弹层

    @ViewBuilder
    private var confirmOverlay: some View {
        if let confirm = model.confirm {
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("数据较多")
                        .font(.headline)
                    Text(confirm.spanText)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    if let count = confirm.estimatedCount {
                        Text("约 \(count) 条样本")
                            .font(.subheadline.weight(.medium))
                            .contentTransition(.numericText())
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("估算中…").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }

                    VStack(spacing: 10) {
                        Button {
                            model.confirmContinueAll()
                        } label: {
                            Text("继续全部").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(confirm.estimatedCount == nil)

                        Button {
                            model.confirmRecentOnly()
                        } label: {
                            Text("仅最近 \(confirm.recentDays) 天").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)

                        Button(role: .cancel) {
                            model.confirmCancel()
                        } label: {
                            Text("取消").frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(24)
                .frame(maxWidth: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .padding(40)
            }
        }
    }

    // MARK: Helpers

    private func binding(for metric: HealthMetric) -> Binding<Bool> {
        Binding(
            get: { model.settings.selectedMetrics.contains(metric) },
            set: { isOn in
                if isOn { model.settings.selectedMetrics.insert(metric) }
                else { model.settings.selectedMetrics.remove(metric) }
            }
        )
    }

    private func subtitle(for metric: HealthMetric) -> String {
        let base = metric.category.displayName
        guard model.hasProbed else { return base }
        if let date = model.probeDates[metric] {
            return base + " · 最近 " + date.formatted(.relative(presentation: .named))
        } else {
            return base + " · 无数据或未授权"
        }
    }

    private var incrementalSyncText: String {
        if let date = model.settings.lastSyncDate {
            return "上次同步：" + date.formatted(date: .abbreviated, time: .shortened)
        } else {
            return "尚未同步过（将导出全部历史）"
        }
    }

    private var modeBinding: Binding<SyncMode> {
        Binding(get: { model.settings.mode }, set: { model.settings.mode = $0 })
    }

    private var rangeStartBinding: Binding<Date> {
        Binding(get: { model.settings.rangeStart }, set: { model.settings.rangeStart = $0 })
    }

    private var rangeEndBinding: Binding<Date> {
        Binding(get: { model.settings.rangeEnd }, set: { model.settings.rangeEnd = $0 })
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

#Preview {
    ContentView()
}
