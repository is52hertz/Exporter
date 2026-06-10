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
- **数据点（全量）**：覆盖 iOS 26.5 SDK 全部可读类型 —— 120 quantity + 69 category + 8 特殊类型（体能训练 / 心境 / 心电图 / 听力图 / GAD-7 / PHQ-9 / 视力处方 / 用药记录）+ 6 项个人特征（profile）。目录数据驱动（`HealthMetric.registered`，由 SDK 头文件机械生成，官方中文名），新增指标只需在注册表加一行。
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
    HealthMetric.swift         全量数据类型目录：197 项（120q+69c+8特殊）+ HealthCategory 14 分类（纯描述符，nonisolated）
    HealthKitManager.swift     授权（标准+逐对象）+ 查询（并发窗口 12）+ 按 kind 分派转换 + 全部值名称表 + profile 读取
  Model/
    HealthSample.swift         归一化中间模型（nonisolated Sendable，extra 携带特殊类型附加列）
    JSONValue.swift            附加列递归值类型（number/string/array/null）
    ExportProfile.swift        个人特征（出生日期/性别/血型/肤型/轮椅/活动模式）
    ExportDocument.swift       schema v3 顶层文档：分组 + columns/rows + extraColumns + profile + 来源索引表
    SyncMode.swift             同步模式枚举（增量 / 日期段）
  Export/
    JSONExporter.swift         自定义字符串序列化器（nonisolated，row 单行紧凑排版）
    Sender.swift               ExportSender 协议 + HTTPSender + SenderError（nonisolated）
  Store/
    AnchorStore.swift          增量 anchor 持久化（nonisolated struct，UserDefaults）
    AppSettings.swift          @MainActor @Observable 用户配置
  UI/
    ExportModel.swift          @MainActor @Observable，UI 状态/流程单一来源（懒探测缓存）
    JSONPreviewView.swift      预览 sheet：摘要卡 + 截断片段 + 文件 ShareLink + 发送
    SettingsView.swift         endpoint / Authorization 头 / 大导出阈值 / UUID 开关
ExporterTests/ExporterTests.swift   JSONExporter 单测（Swift Testing）
```

**分层职责**：Health（读取）→ Model（归一化数据）→ Export（编码/发送）→ Store（持久化）→ UI（展示/协调）。

## 4. JSON Schema（v3）

`ExportDocument` 经 `JSONExporter`（自定义字符串序列化器，非 JSONEncoder）输出。设计目标：消除逐条对象的键名/uuid/双时间戳冗余，对 LLM 与人都好读 —— 顶层美化缩进、**每条样本 row 单行**：

```json
{
  "schemaVersion": 3,
  "exportedAt": "ISO8601",
  "device": { "model": "iPhone", "os": "iOS 26.5" },
  "range": { "mode": "incremental|range", "start": "ISO8601?", "end": "ISO8601?" },
  "profile": { "dateOfBirth": "1990-01-31", "biologicalSex": "male", "bloodType": "oPositive" },
  "sources": ["Apple Watch", "iPhone"],
  "metrics": {
    "heartRate": {
      "category": "heart",
      "unit": "count/min",
      "count": 9800,
      "columns": ["start", "durationSec", "value", "source"],
      "rows": [
        ["2026-06-09T08:00:00Z", 0, 72, 0],
        ["2026-06-09T08:00:05Z", 0, 73.5, 0]
      ]
    },
    "workout": {
      "category": "workout",
      "count": 12,
      "columns": ["start", "durationSec", "value", "source", "kcal", "distanceKm"],
      "rows": [
        ["2026-06-09T18:00:00Z", 1800, "running", 0, 320, 5.2]
      ]
    },
    "stateOfMind": {
      "category": "mindfulness",
      "count": 3,
      "columns": ["start", "durationSec", "value", "source", "kind", "classification", "labels", "associations"],
      "rows": [
        ["2026-06-09T21:00:00Z", 0, 0.5, 1, "momentaryEmotion", "pleasant", ["happy", "calm"], ["fitness"]]
      ]
    }
  }
}
```

- 按指标分组：`type`/`category`/`unit` 提升到组级；`unit` 仅 quantity 组有。
- 时间 = `start`（ISO8601）+ `durationSec`（整数秒）；瞬时样本（如心率）时长为 0。
- `source` 列是顶层 `sources` 数组的下标（来源名去重）。
- quantity 的 `value` 是数字（整数值不带 `.0`），category 的是字符串（值名称表见 `HealthKitManager.categoryValueName`：睡眠阶段、症状 severity、经期枚举等；事件型 `notApplicable` → `"occurred"`）。
- **特殊类型附加列**（`HealthMetric.extraColumns`，主值 = value 列）：
  - `workout`：value=运动类型（英文驼峰，`workoutActivityName` 全表），+`kcal`/`distanceKm`
  - `stateOfMind`：value=愉悦度 (-1…1)，+`kind`/`classification`/`labels`/`associations`（嵌套字符串数组）
  - `electrocardiogram`：value=分类结果，+`avgBPM`/`samplingHz`/`voltagePoints`（仅摘要，不含逐点波形）
  - `audiogram`：value=测试点数，+`points` = `[[频率Hz, 左耳dBHL?, 右耳dBHL?], …]`
  - `GAD7`/`PHQ9`：value=得分，+`risk`
  - `visionPrescription`：value=glasses/contacts，+`issued`/`expires`
  - `medicationDoseEvent`：value=记录状态（taken/skipped/…），+`concept`/`dose`/`doseUnit`
- 省略约定：对象可选键缺省不写；row 单元格仅在附加列缺测时为 `null`（定宽行）。
- `profile`：个人特征（characteristics），无任何已授权项时整体省略。
- 设置「样本包含 UUID」开启时，`columns` 末尾追加 `"uuid"`（接收端精确去重用；默认关）。
- metrics 按 `HealthMetric.registered` 顺序、组内按 start 升序，输出确定性，单测锁定。
- 历史：v1（逐条对象数组）→ v2（分组紧凑行，commit `3db83a4`）→ v3（全量目录 + profile + extraColumns）。无线上接收端兼容包袱。

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

### 导出提速 + Schema v2（本轮）
1. **Schema v2 紧凑格式**（见 §4）：`ExportDocument` 按指标分组 + columns/rows 单行紧凑行 + 来源索引表 + start/durationSec 时间编码；UUID 改为设置开关（默认关）。高频数据下文件体积约缩至 v1 的 1/4。
2. **自定义序列化器**：`JSONExporter` 弃用 JSONEncoder（`.prettyPrinted` 会把 row 数组每元素炸成一行，Codable 路径也慢），改为直接字符串构建（共享 `ISO8601DateFormatter`、`reserveCapacity`、整数值不带 `.0`）。
3. **预览不再卡死**：根因是 `JSONPreviewView` 用单个 `Text` 渲染整个多 MB JSON 字符串，SwiftUI 超长 Text 布局在主线程。现改为：后台序列化 → 写临时文件（`tmp/HealthExport-<时间戳>.json`，写前删上一份）→ 截取前 64KB（按行边界）作预览片段；主线程只持有轻量摘要状态（文件 URL、字节数、各指标条数、数据范围），不再常驻 `samples`/`jsonString` 两份大数据。
4. **分享/发送走文件**：`ShareLink(item: fileURL)` 分享 `.json` 文件（替代大字符串分享）；发送 API 时从文件后台读 `Data`。
5. **预览 UI**：摘要卡（GroupBox：文件大小/数据范围/各指标条数）+ 截断片段 + 「预览已截断」提示。

### 全量健康&健身目录（本轮，schema v3）
1. **HealthMetric 重构**：枚举 → 数据驱动 struct 目录，197 项（120 quantity + 69 category + 8 特殊），由 SDK 头文件 `HKTypeIdentifiers.h` 机械生成（单位取头文件注释），官方中文名；`HealthCategory` 扩为健康 App 同款 14 分类。旧四指标 rawValue 不变，anchor/设置持久化兼容。
2. **HK 映射**：标识符 = `rawValue` 首字母大写 + 特例表（`VO2Max`/`UVExposure`/`AudioExposureEvent` 历史更名）；单位 = 显式 `HKUnit` 字典（25 种，不用 `HKUnit(from:)` 解析）。两者均有全量单测。
3. **转换按 kind 分派**：quantity/category 通用路径 + 7 种特殊样本类型专属转换（见 §4 附加列）；category 值名称表覆盖睡眠/症状/经期/事件等全部已知枚举。
4. **授权**：标准读集合 + characteristics 一并请求；**逐对象授权类型（视力处方/用药）绝不能进标准授权 API**（见 §13）。
5. **并发窗口**：fetch 同时最多 12 个 HK 查询（近 200 类型不再无界并发）。
6. **UI**：指标区改为 14 分类 `DisclosureGroup`（默认收起）+ 组全选 + 顶部全选/全不选 + 已选计数；探测改为懒加载（展开分类才查询该组，结果缓存，启动零查询）。
7. **Profile**：导出时后台读取个人特征，写入顶层 `profile`。

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
- **ECG 仅导出摘要**（分类/平均心率/采样率/电压点数），不含逐点波形（每条 ~15000 点，体积失衡）。
- **用药**：仅导出剂量事件；`concept` 为标识符字符串（药物名需 `HKUserAnnotatedMedicationQuery`，留后续）；授权经由「按药物逐对象授权」面板。
- **授权是三段式**：健康数据（标准面板）→ 用药（逐对象）→ 验光处方（逐对象），三个系统面板依次弹出且无法合并；App 在发起前用 alert 预告流程。
- **不导出**：训练 GPS 路线（HKSeriesType）、活动圆环摘要（三环已含于 quantity）、临床记录（需特殊 entitlement + FHIR）。

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
- `3db83a4` — schema v2 紧凑格式 + 文件落盘预览：导出提速、预览不再卡死（feat/json-export-v2 分支）。
- `db05de4` — 全量健康&健身数据目录（197 项）+ schema v3：数据驱动目录、特殊类型、逐对象授权修复、分类折叠 UI（feat/full-health-catalog 分支）。

## 13. 坑 / 注意

- **SourceKit 跨文件索引滞后**：在 Xcode 之外用工具新增/改文件后，编辑器常报「Cannot find type X in scope」误报，但 `xcodebuild` 干净通过。处理：`⌘B` 重新编译 / `⇧⌘K` 清理 / 重开工程。**以 `xcodebuild` 结果为准，别被实时报错带偏。**
- **逐对象授权类型会炸标准授权 API**：把 `visionPrescriptionType` / `medicationDoseEventType` 放进 `requestAuthorization` 或 `getRequestStatusForAuthorization` 的读集合 → HealthKit 抛 `NSInvalidArgumentException`（启动即崩，曾踩）。必须走 `requestPerObjectReadAuthorization`（用药目标是 `userAnnotatedMedicationType`），并对这两类的查询失败做容错。`requiresPerObjectAuthorization()` 对 dose event 类型返回 false，不能只靠它过滤 —— 需按 kind 显式排除。
- **历史更名标识符**：`environmentalAudioExposureEvent` 的原始字符串仍是 `HKCategoryTypeIdentifierAudioExposureEvent`；机械拼接标识符时需特例表（另有 `VO2Max`/`UVExposure` 大小写）。单测 `everyMetricResolvesToSampleType` 全量守护。
- **部分类型授权面板不展示（真机踩坑）**：地区/设备功能限制下个别类型（如问卷评估、房颤负荷等）不会出现在授权面板，用户无法授予 → 该类型永远 `notDetermined`：① `getRequestStatusForAuthorization` 对全集永远返回 `shouldRequest`（授权按钮状态需用 `settings.hasRequestedAuthorization` 持久化兜底）；② 查询抛 `errorAuthorizationNotDetermined`（fetch 必须按指标跳过并上报 `skippedMetrics`，不能让单指标炸掉整体导出）。真机现象：授予全部权限后导出仍弹 "Authorization not determined"、按钮不变「管理」。
- 同步文件夹下别手动往 pbxproj 加源文件引用（会重复）。
- `AGENTS.md`（及其符号链接 `CLAUDE.md`）曾是从别的仓库复制来的，已重写为本项目约定。
- 提交前确认 `xcuserdata/` 未被纳入（已 gitignore）。
