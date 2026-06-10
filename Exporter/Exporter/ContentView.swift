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
            .disabled(model.isWorking)
            .overlay {
                if model.isWorking {
                    ProgressView().controlSize(.large)
                }
            }
        }
    }

    // MARK: Sections

    private var authSection: some View {
        Section {
            Button {
                Task { await model.requestAuthorization() }
            } label: {
                Label("请求健康数据授权", systemImage: "heart.text.square")
            }
        } footer: {
            Text("仅读取你授权的数据。HealthKit 不会向 App 透露你“拒绝”了哪些项，读取结果取决于实际授权。")
        }
    }

    private var modeSection: some View {
        Section("时间范围") {
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
        }
    }

    private var metricsSection: some View {
        Section("数据指标") {
            ForEach(HealthMetric.registered) { metric in
                Toggle(isOn: binding(for: metric)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.displayName)
                            Text(metric.category.displayName)
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
                Task { await model.readAndPreview() }
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
