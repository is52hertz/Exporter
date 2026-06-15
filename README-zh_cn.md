<!--
README-zh_cn.md — 简体中文。HTML 在 github.com 上可正常渲染。
-->

<p align="right">
  <a href="README.md">English</a> ·
  <b>简体中文</b> ·
  <a href="README-zh_tw.md">繁體中文</a>
</p>

> **由 AI 构建，由人类指挥。**
> Exporter 端到端由 AI 编码助手开发，开发者担任**创意总监与 QA**。
> `AGENTS.md`、`CLAUDE.md`、`Project.md` 都是**有意**提交进仓库的——这是一个学习项目。读它、fork 它、提 PR。

<br />

<p align="center">
  <img src="Docs/AppIcon-iOS-Default-512x512@1x.png" alt="Exporter 图标" width="180" />
</p>

<h1 align="center">Exporter</h1>

<p align="center">
  一个原生、只读的 iOS App，把你授权的<br/>
  <b>Apple HealthKit</b> 健康 &amp; 健身数据导出为带版本、对 LLM 友好的 <b>JSON</b>。
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/iOS-26-000?logo=apple&logoColor=white" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" />
  <img alt="HealthKit" src="https://img.shields.io/badge/HealthKit-read--only-FF2D55?logo=apple&logoColor=white" />
  <img alt="design" src="https://img.shields.io/badge/Liquid%20Glass-iOS%2026-1B7CD5" />
  <img alt="license" src="https://img.shields.io/badge/license-GPL--3.0-success" />
</p>

---

## Exporter 是什么？

Exporter 读取**你授权的** HealthKit 数据，归一化为单一、带版本的 JSON schema，然后让你既能
**在本机预览 / 分享**，也能 **POST 到你自己配置的远程 API**。它对 HealthKit **只读**——绝不写入、
绝不删除。

它是一个小而单用户的 App，面向**个人 / 自用**——**不上架** App Store。除了你**亲自配置的那一个端点**，
你的数据不会流向任何地方：无账号、无遥测、无第三方。

导出的 JSON 刻意做得紧凑、对**人和 LLM**都好读：样本按指标分组，列名与时间戳从每一行里提到组级，
来源去重收进一张索引表。

---

## ✨ 功能

- 🩺 **全量 HealthKit 目录** —— 数据驱动的类型表，**约 197 个可读类型**（120 quantity + 69 category
  + 8 个特殊类型：体能训练、心境 State of Mind、心电图、听力图、GAD-7、PHQ-9、视力处方、用药剂量事件），
  外加 6 项个人**特征**（出生日期、生理性别、血型……）。新增一个指标只需在注册表加一行。
- 🔐 **只读授权** —— 仅请求 `read` 权限（`toShare: []`）。逐对象授权类型（视力处方、用药）走各自专属的
  授权流程。被拒绝的读取与「无数据」无法区分，因此所有状态措辞都保守。
- 🧱 **带版本的 JSON schema（v3）** —— 指标分组、组级 `category`/`unit`、紧凑的 `columns`/`rows`
  （一条样本一行）、特殊类型的逐指标 `extraColumns`、可选的顶层 `profile`、ISO-8601 时间，以及去重的
  `sources` 索引。由自定义字符串序列化器（非 `JSONEncoder`）输出，兼顾速度与精确排版。
- ⏱️ **两种读取模式** —— **增量**（`HKAnchoredObjectQuery` + *延迟提交 anchor*，取消导出绝不前移你的
  同步游标）与**指定日期段**（`HKSampleQuery`）。
- 📤 **本地或远程导出** —— 用 `ShareLink` 分享 / 复制 `.json`，或带可选 `Authorization` 头 POST 到你的
  端点。未配置端点时优雅降级为本机预览。发送到远程端点始终是一次明确、需确认的动作。
- ⚡ **不阻塞主线程** —— 数据模型、HealthKit 查询、JSON 编码、网络都是 `nonisolated` / `Sendable`；
  查询用 `withThrowingTaskGroup` 并发（有界窗口），编码在 detached 任务上跑。大导出落盘到临时文件——
  UI 只持有摘要 + 截断预览，绝不常驻整份 JSON 字符串。
- 🪟 **Liquid Glass 界面** —— iOS 26 上 SwiftUI 优先、符合 HIG，支持浅 / 深色、动态字体与 VoiceOver。

---

## 🧾 JSON（schema v3）

```jsonc
{
  "schemaVersion": 3,
  "exportedAt": "2026-06-15T10:00:00Z",
  "device": { "model": "iPhone", "os": "iOS 26.5" },
  "range": { "mode": "incremental" },
  "profile": { "dateOfBirth": "1990-01-31", "biologicalSex": "male" },
  "sources": ["Apple Watch", "iPhone"],
  "metrics": {
    "heartRate": {
      "category": "heart",
      "unit": "count/min",
      "count": 2,
      "columns": ["start", "durationSec", "value", "source"],
      "rows": [
        ["2026-06-09T08:00:00Z", 0, 72, 0],
        ["2026-06-09T08:00:05Z", 0, 73.5, 0]
      ]
    }
  }
}
```

- 指标分组，`category`/`unit` 提到组级；`source` 是顶层 `sources` 数组的下标；时间 = `start`
  （ISO-8601）+ 整数 `durationSec`。
- 特殊类型带附加列——如 `workout` 加 `kcal`/`distanceKm`，`ecg` 加 `avgBPM`/`samplingHz`。
  输出顺序确定，由单测锁定。

---

## 💻 运行要求

- **iPhone**，**iOS 26+**（部署目标 26.5）。
- 构建需 **Xcode 26**。不支持 macOS / watchOS / iPadOS（仅 iPhone 上的 HealthKit）。

---

## 🛠 从源码构建

```sh
git clone https://github.com/is52hertz/Exporter.git
cd Exporter
open Exporter/Exporter.xcodeproj      # 用 Xcode 26 打开，连真机后 ⌘R
```

或命令行：

```sh
# 构建（模拟器）
xcodebuild -project Exporter/Exporter.xcodeproj -scheme Exporter \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# 测试（JSON 序列化器 + 指标目录单测）
xcodebuild test -project Exporter/Exporter.xcodeproj -scheme Exporter \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ExporterTests
```

> 模拟器上 HealthKit 几乎没有数据，授权面板也需要真实点按——授权流程、真实读取与性能应在**真机**上验证。

---

## 🕵️ 隐私

对 HealthKit 只读。无账号、无分析、无遥测。你的健康数据不会离开设备，**除非**发送到你在「设置」里亲自填写的
那一个远程端点——而且只在你确认发送时。无私有 API，不执行下载的 / 任意代码。

---

## 🤖 AI-native 开发

本仓库是 **AI-native 开发**的一个范例。助手所需的上下文都是**有意**提交进来的：

| 文件 | 用途 |
|---|---|
| `AGENTS.md` | **唯一事实来源** —— 产品规则、编码规范、范围纪律、提交策略。 |
| `CLAUDE.md` | 各工具入口（指向 `AGENTS.md` 的符号链接）。 |
| `Project.md` | 交接文档 —— 架构、schema、关键决策、平台坑。 |

> 由 AI 构建，由人类指挥。读这些文件、fork 这个仓库，看看它是怎么做出来的。

---

## 📜 许可

以 **GNU 通用公共许可证 v3.0**（GPL-3.0）发布。

> 为什么是 GPL？这个项目为教学而存在。GPL 保证衍生作品——包括 AI 生成的 fork——保持开放，让下一个学习者
> 也能研究它。如果你在它之上构建，请回馈开源。

Copyright (C) 2026 Teethe。完整条款见 [`LICENSE`](LICENSE)。
