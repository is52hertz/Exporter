<!--
README-zh_tw.md — 繁體中文。HTML 在 github.com 上可正常渲染。
-->

<p align="right">
  <a href="README.md">English</a> ·
  <a href="README-zh_cn.md">简体中文</a> ·
  <b>繁體中文</b>
</p>

> **由 AI 構建，由人類指揮。**
> Exporter 端到端由 AI 編碼助手開發，開發者擔任**創意總監與 QA**。
> `AGENTS.md`、`CLAUDE.md`、`Project.md` 都是**刻意**提交進倉庫的——這是一個學習專案。讀它、fork 它、提 PR。

<br />

<p align="center">
  <img src="Docs/AppIcon-iOS-Default-512x512@1x.png" alt="Exporter 圖示" width="180" />
</p>

<h1 align="center">Exporter</h1>

<p align="center">
  一個原生、唯讀的 iOS App，把你授權的<br/>
  <b>Apple HealthKit</b> 健康 &amp; 健身資料匯出為帶版本、對 LLM 友善的 <b>JSON</b>。
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/iOS-26-000?logo=apple&logoColor=white" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" />
  <img alt="HealthKit" src="https://img.shields.io/badge/HealthKit-read--only-FF2D55?logo=apple&logoColor=white" />
  <img alt="design" src="https://img.shields.io/badge/Liquid%20Glass-iOS%2026-1B7CD5" />
  <img alt="license" src="https://img.shields.io/badge/license-GPL--3.0-success" />
</p>

---

## Exporter 是什麼？

Exporter 讀取**你授權的** HealthKit 資料，正規化為單一、帶版本的 JSON schema，然後讓你既能
**在本機預覽 / 分享**，也能 **POST 到你自己設定的遠端 API**。它對 HealthKit **唯讀**——絕不寫入、
絕不刪除。

它是一個小而單一使用者的 App，面向**個人 / 自用**——**不上架** App Store。除了你**親自設定的主要位址或選填的備用位址**，
你的資料不會流向任何地方：無帳號、無遙測、無第三方。

匯出的 JSON 刻意做得精簡、對**人和 LLM**都好讀：樣本依指標分組，欄名與時間戳從每一列裡提到群組層級，
來源去重收進一張索引表。

---

## ✨ 功能

- 🩺 **全量 HealthKit 目錄** —— 資料驅動的型別表，**約 197 個可讀型別**（120 quantity + 69 category
  + 8 個特殊型別：體能訓練、心境 State of Mind、心電圖、聽力圖、GAD-7、PHQ-9、視力處方、用藥劑量事件），
  外加 6 項個人**特徵**（出生日期、生理性別、血型……）。新增一個指標只需在註冊表加一行。
- 🔐 **唯讀授權** —— 僅請求 `read` 權限（`toShare: []`）。逐物件授權型別（視力處方、用藥）走各自專屬的
  授權流程。被拒絕的讀取與「無資料」無法區分，因此所有狀態用詞都保守。
- 🧱 **帶版本的 JSON schema（v3）** —— 指標分組、群組層級 `category`/`unit`、精簡的 `columns`/`rows`
  （一筆樣本一列）、特殊型別的逐指標 `extraColumns`、可選的頂層 `profile`、ISO-8601 時間，以及去重的
  `sources` 索引。由自訂字串序列化器（非 `JSONEncoder`）輸出，兼顧速度與精確排版。
- ⏱️ **兩種讀取模式** —— **增量**（`HKAnchoredObjectQuery` + *延遲提交 anchor*，取消匯出絕不前移你的
  同步游標）與**指定日期區間**（`HKSampleQuery`）。
- 📤 **本機或遠端匯出** —— 用 `ShareLink` 分享 / 複製 `.json`，或帶可選 `Authorization` 標頭 POST 到你的
  端點。未設定端點時優雅降級為本機預覽。傳送到遠端端點始終是一次明確、需確認的動作。
- ⚡ **不阻塞主執行緒** —— 資料模型、HealthKit 查詢、JSON 編碼、網路都是 `nonisolated` / `Sendable`；
  查詢用 `withThrowingTaskGroup` 並行（有界視窗），編碼在 detached 任務上跑。大型匯出落地到暫存檔——
  UI 只持有摘要 + 截斷預覽，絕不常駐整份 JSON 字串。
- 🪟 **Liquid Glass 介面** —— iOS 26 上 SwiftUI 優先、符合 HIG，支援淺 / 深色、動態字級與 VoiceOver。

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

- 指標分組，`category`/`unit` 提到群組層級；`source` 是頂層 `sources` 陣列的索引；時間 = `start`
  （ISO-8601）+ 整數 `durationSec`。
- 特殊型別帶附加欄——如 `workout` 加 `kcal`/`distanceKm`，`ecg` 加 `avgBPM`/`samplingHz`。
  輸出順序確定，由單元測試鎖定。

---

## 💻 執行需求

- **iPhone**，**iOS 26+**（部署目標 26.5）。
- 建置需 **Xcode 26**。不支援 macOS / watchOS / iPadOS（僅 iPhone 上的 HealthKit）。

---

## 🛠 從原始碼建置

```sh
git clone https://github.com/is52hertz/Exporter.git
cd Exporter
open Exporter/Exporter.xcodeproj      # 用 Xcode 26 開啟，接實機後 ⌘R
```

或命令列：

```sh
# 建置（模擬器）
xcodebuild -project Exporter/Exporter.xcodeproj -scheme Exporter \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# 測試（JSON 序列化器 + 指標目錄單元測試）
xcodebuild test -project Exporter/Exporter.xcodeproj -scheme Exporter \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ExporterTests
```

> 模擬器上 HealthKit 幾乎沒有資料，授權面板也需要真實點按——授權流程、真實讀取與效能應在**實機**上驗證。

---

## 🕵️ 隱私

對 HealthKit 唯讀。無帳號、無分析、無遙測。手動傳送或開啟背景增量推送後，資料只會傳送到你在「設定」中點「完成」儲存的位址。
主要位址只支援 HTTPS；備用位址只在使用私人或鏈路本地 IP、或 `.local` 網域名稱時可用 HTTP。HTTP 不會加密健康資料或 Authorization 標頭，請只在信任的網路上使用。
`.local` 網域名稱依賴裝置的系統解析和路由，名稱本身不能驗證接收端身分。建議先在區域網路手動傳送一次；如果 iOS 提示取用區域網路，請允許。
只有確認請求沒有送往主要位址時才嘗試備用位址；收到 HTTP 回應後不切換，也不跟隨重新導向。若傳送結果未確認，請先檢查接收端再重送。無私有 API，不執行任意程式碼。

---

## 🤖 AI-native 開發

本倉庫是 **AI-native 開發**的一個範例。助手所需的脈絡都是**刻意**提交進來的：

| 檔案 | 用途 |
|---|---|
| `AGENTS.md` | **唯一事實來源** —— 產品規則、編碼規範、範圍紀律、提交策略。 |
| `CLAUDE.md` | 各工具入口（指向 `AGENTS.md` 的符號連結）。 |
| `Project.md` | 交接文件 —— 架構、schema、關鍵決策、平台坑。 |

> 由 AI 構建，由人類指揮。讀這些檔案、fork 這個倉庫，看看它是怎麼做出來的。

---

## 📜 授權

以 **GNU 通用公共授權條款 v3.0**（GPL-3.0）發布。

> 為什麼是 GPL？這個專案為教學而存在。GPL 保證衍生作品——包括 AI 生成的 fork——保持開放，讓下一個學習者
> 也能研究它。如果你在它之上構建，請回饋開源。

Copyright (C) 2026 Teethe。完整條款見 [`LICENSE`](LICENSE)。
