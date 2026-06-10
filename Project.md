# Project.md — Exporter 交接文档

> 给下一个 AI / 开发者的完整交接。本文件记录架构、已实现功能、关键决策与约束、约定与坑。
> 持久化的编码规则见 `AGENTS.md`；本文件可包含进度与路线图。

---

## 1. 项目目标

`Exporter` 是一个 Apple 原生 App（Swift + SwiftUI），读取用户授权的 **HealthKit** 健康/健身数据，归一化为统一 schema 的 **JSON**，并能：
- 在本机**预览**、通过 `ShareLink` **分享/复制**；
- **POST** 到用户配置的远程 API。

候选（未做）：快捷指令（App Intents）让用户自动保存/转发。

**分发**：自用/个人，不上架。**bundle id**：`cn.Teethe.Exporter`。

## 2. 需求确认（与用户逐项敲定的决策）

- **平台**：MVP 仅 iPhone (iOS 26)。Watch / iPad / 后台自动 / 快捷指令留后续。app target 已收窄为 iOS-only（macOS 无 HealthKit）。
- **同步触发**：手动点击（后台自动留后续）。
- **数据点（MVP）**：步数 `stepCount`、活动能量 `activeEnergyBurned`、心率 `heartRate`、睡眠分析 `sleepAnalysis`——覆盖 累计 quantity / 离散 quantity / category 三种形态。新增指标只需在 `HealthMetric` 加 case + 补映射。
- **时间范围**：两种模式——**增量**（`HKAnchoredObjectQuery` anchor 持久化）与**指定日期段**。
- **JSON schema**：自设计（见 §4）。
- **API 认证**：尚未定 → 发送层做成可插拔协议，现支持「填 endpoint + 可选 Authorization 头 POST」或「本机预览/分享」，认证方式定了再补具体实现。
- **UI**：必须符合 HIG，采用 iOS 26 **Liquid Glass**。

## 3. 架构与文件结构

工程在 `Exporter/`（含 `Exporter.xcodeproj`）。**Xcode 同步文件夹**（PBXFileSystemSynchronizedRootGroup，objectVersion 77）——`Exporter/Exporter/` 下新增的 `.swift` 自动加入 target，无需手改 pbxproj。

```
Exporter/Exporter/
  ExporterApp.swift            @main，WindowGroup → ContentView
  ContentView.swift            主界面（授权/模式/指标/导出/确认弹层）
  Exporter.entitlements        com.apple.developer.healthkit
  Health/
    HealthMetric.swift         数据类型表：HealthMetric / HealthCategory（纯描述符，nonisolated）
    HealthKitManager.swift     授权 + 查询 + 探测 + HK 映射扩展（@MainActor 类，查询方法 nonisolated）
  Model/
    HealthSample.swift         归一化中间模型（nonisolated Codable Sendable）
    ExportEnvelope.swift       JSON 顶层信封 + SyncMode（nonisolated Sendable）
  Export/
    JSONExporter.swift         编码（nonisolated）
    Sender.swift               ExportSender 协议 + HTTPSender + SenderError（nonisolated）
  Store/
    AnchorStore.swift          增量 anchor 持久化（nonisolated struct，UserDefaults）
    AppSettings.swift          @MainActor @Observable 用户配置
  UI/
    ExportModel.swift          @MainActor @Observable，UI 状态/流程单一来源
    JSONPreviewView.swift      预览 sheet + ShareLink + 发送
    SettingsView.swift         endpoint / Authorization 头 / 大导出阈值
ExporterTests/ExporterTests.swift   JSONExporter 单测（Swift Testing）
```

**分层职责**：Health（读取）→ Model（归一化数据）→ Export（编码/发送）→ Store（持久化）→ UI（展示/协调）。

## 4. JSON Schema

`ExportEnvelope` 编码（`JSONExporter`：`.iso8601` 时间、`.prettyPrinted`、`.sortedKeys`、`.withoutEscapingSlashes`）：

```json
{
  "schemaVersion": 1,
  "exportedAt": "ISO8601",
  "device": { "model": "iPhone", "os": "iOS 26.5" },
  "range": { "mode": "incremental|range", "start": "ISO8601?", "end": "ISO8601?" },
  "samples": [
    {
      "type": "stepCount", "category": "activity",
      "value": 1234, "unit": "count",          // quantity 样本
      "start": "ISO8601", "end": "ISO8601",
      "source": "Apple Watch", "uuid": "…"
    },
    {
      "type": "sleepAnalysis", "category": "sleep",
      "stringValue": "asleepCore",              // category 样本（无 value/unit）
      "start": "ISO8601", "end": "ISO8601", "source": "iPhone", "uuid": "…"
    }
  ]
}
```

- `HealthSample`：quantity 填 `value`+`unit`；category 填 `stringValue`。synthesized Codable 用 `encodeIfPresent`，nil 字段自动省略（单测有断言）。
- 睡眠 `stringValue` 映射 `HKCategoryValueSleepAnalysis`：`inBed/asleepUnspecified/awake/asleepCore/asleepDeep/asleepREM`。
- `uuid` = `HKObject.uuid`，用于去重。

## 5. 已实现功能

### MVP（commit `84af50d`）
- HealthKit 只读授权（`requestAuthorization(toShare:[], read:)`）。
- 增量（anchored）与日期段（sample query）读取，归一化为 `[HealthSample]`。
- JSON 编码、预览 sheet、`ShareLink` 分享、`HTTPSender` 占位发送。
- 标准系统大标题 UI + 工具栏设置；指标多选、模式分段、日期选择。

### 体验与性能改进（commit `4f2372f`）
1. **异步导出 / 不卡 UI**：根因是工程 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 让所有代码默认在主线程。把数据/查询/编码标 `nonisolated` 移出主线程；编码走 `Task.detached(.userInitiated)`；UI 状态仍在主线程更新。
2. **性能**：各指标查询用 `withThrowingTaskGroup` 并行（原为串行 for）。
3. **授权按钮可再触发**：HealthKit 面板系统只弹一次。用 `getRequestStatusForAuthorization` 判断——未决弹面板；已决（`.unnecessary`）弹说明 alert + 「去设置」（`openSettingsURLString`）。按钮文案动态。
4. **轻量探测显示状态**：授权后/进入时并行跑 limit=1 查询（`probeLatest`），保守标注每个指标「最近 X」/「无数据或未授权」。
5. **增量显示上次同步**：`AppSettings.lastSyncDate` 持久化，增量模式显示「上次同步：X」/「尚未同步过（将导出全部历史）」。
6. **大导出确认弹层**：导出跨度 > 阈值（`largeExportThresholdDays`，默认 3 天，设置里可配）时，弹自定义弹层（非系统 alert，因 alert 文案弹出后不可更新）：先显示「估算中…」，后台查询返回后异步填入「约 N 条样本」；按钮 **继续全部 / 仅最近 N 天 / 取消**。

## 6. 关键技术决策与理由

- **并发隔离**：工程全局默认 MainActor。只把「纯数据 + 查询 + 编码 + 网络」标 `nonisolated`/`Sendable` 移出主线程；UI 状态类（`ExportModel`/`AppSettings`/`HealthKitManager` 的可观察状态）保持 `@MainActor`。`@MainActor` class 隐式 `Sendable`，可在任务组捕获 `self`。`HealthKitManager` 的 `healthStore`/`anchorStore` 用 `nonisolated let`（二者 Sendable/线程安全）以便后台查询方法访问。目标：编译零警告（Swift 5 模式下隔离冲突仅警告）。
- **anchor 延迟提交**（重要正确性）：为给确认弹层估算条数会先跑完整查询；若此时立即落盘 anchor，用户点「取消」后 anchor 已错误前移 → 下次增量漏数据。故 `fetchIncremental` **不落盘 anchor**，把新 anchor 归档为 `Data` 随 `FetchOutcome` 带回；只有用户确认「继续全部」/小跨度直接导出时才 `health.commit(outcome)` 落盘并更新 `lastSyncDate`。「仅最近 N 天」「取消」都不动 anchor/lastSyncDate。anchor 以 `Data` 跨任务边界传递，保持 `Sendable` 零警告。
- **不双查**：确认弹层的预估与「继续全部」复用**同一次**查询结果（`pendingOutcome`），不重复昂贵查询。
- **「仅最近 N 天」语义**：走 `mode: .range`、`[now-N, now]` 局部读取，不推进 anchor、不更新 lastSyncDate，保持增量语义干净。
- **授权状态不可知**：HealthKit 不暴露读权限具体状态、对拒绝读取静默返回空且不报错 → 无法区分「未授权」与「确实无数据」。因此探测只能正向确认（读到=有数据/已授权），UI 一律保守措辞。
- **首次增量 = 全部历史**：用户选择**不加硬上限**，靠确认弹层告知；`fetch(maxLookback:)` 留参数活口，本轮未接 UI。
- **ExportModel 不 import HealthKit**：通过 `HealthKitManager.isAuthorizationDetermined(for:) -> Bool` 等 Bool/中性返回值避免在 UI 层引入 HK 类型；`FetchOutcome` 是本模块内类型，ExportModel 仅持有/回传不触碰其内部 HK 成员。

## 7. 平台与工程配置

- **工具链**：Xcode 26.5 / iOS 26.5 SDK。`IPHONEOS_DEPLOYMENT_TARGET = 26.5`。
- **target**：`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"`（app target，已从默认的含 macosx/xros 收窄；因 macOS 无 HealthKit）。
- **Info / 权限**：`GENERATE_INFOPLIST_FILE = YES`（无独立 Info.plist）；`INFOPLIST_KEY_NSHealthShareUsageDescription` 注入用途字符串；`CODE_SIGN_ENTITLEMENTS = Exporter/Exporter.entitlements`（含 `com.apple.developer.healthkit`）。
- **签名**：`DEVELOPMENT_TEAM = 29QGYWRLCD`，automatic。模拟器构建无需 provisioning。

## 8. UI / HIG 决策

- **Liquid Glass**：iOS 26 SDK 编译时标准组件自动获得玻璃外观。主操作按钮用 `.buttonStyle(.glassProminent)`，次级用 `.glass`。不滥用、不 glass 叠 glass、不手搓玻璃。
- **标题布局（一段插曲，结论持久）**：曾尝试自定义 header 把大标题与齿轮放同一行，用户指出 Apple 健康/音乐/App Store 的「大标题左 + 圆形账户/设置按钮右、同一行」本就是标准模式（见记忆 `hig-large-title-trailing-button`）。**最终采用标准系统大标题导航栏 + 工具栏齿轮**（系统统一边距，避免自定义 padding 偏多），并以此为提交基线。若日后要做 Apple-Health 式同行标题，应把标题区作为可滚动内容首行、不要 `.background(.bar)` 假工具栏、不要 `safeAreaInset` 钉死。
- **确认弹层**用自定义 overlay（卡片 + `.regularMaterial`）而非系统 `.alert`，以支持条数异步填入与 `.numericText()` 过渡。

## 9. 已知限制 / 平台约束

- 授权面板系统只弹一次，App 内无法重新弹（只能引导设置）。
- 探测无法区分「未授权」与「无数据」（见 §6）。
- 模拟器 HealthKit 数据极少，且 `simctl` 无法模拟点按 → 确认弹层、真实读取、性能需**真机**验证。
- macOS/visionOS 未支持（target 仅 iOS）。

## 10. 路线图（候选，未做）

Watch + iPad 适配、后台自动同步（`HKObserverQuery` + BackgroundDelivery）、App Intents / 快捷指令、真实 API 认证（如 OAuth）、扩展全量健康指标、把 `maxLookback` 接入 UI。

## 11. 命令

```bash
# 构建（模拟器）
xcodebuild -scheme Exporter -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
# 单测
xcodebuild test -scheme Exporter -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ExporterTests
# 安装运行 + 截图
xcrun simctl boot "iPhone 17 Pro"; \
xcrun simctl install booted <Exporter.app 路径>; \
xcrun simctl launch booted cn.Teethe.Exporter; \
xcrun simctl io booted screenshot /tmp/shot.png
```

## 12. 提交历史

- `84af50d` — Exporter MVP：HealthKit → JSON 导出（第一版 UI）。
- `4f2372f` — 体验与性能改进：异步导出、并行查询、授权/状态可见性、大导出确认、anchor 延迟提交。

## 13. 坑 / 注意

- **SourceKit 跨文件索引滞后**：在 Xcode 之外用工具新增/改文件后，编辑器常报「Cannot find type X in scope」误报，但 `xcodebuild` 干净通过。处理：`⌘B` 重新编译 / `⇧⌘K` 清理 / 重开工程。**以 `xcodebuild` 结果为准，别被实时报错带偏。**
- 同步文件夹下别手动往 pbxproj 加源文件引用（会重复）。
- `AGENTS.md`（及其符号链接 `CLAUDE.md`）曾是从别的仓库复制来的，已重写为本项目约定。
- 提交前确认 `xcuserdata/` 未被纳入（已 gitignore）。
