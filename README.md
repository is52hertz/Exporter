<!--
README.md — written to be both human-friendly on GitHub and learning-friendly
for AI assistants opening the repo. The HTML below renders on github.com.
-->

<p align="right">
  <b>English</b> ·
  <a href="README-zh_cn.md">简体中文</a> ·
  <a href="README-zh_tw.md">繁體中文</a>
</p>

> **Built with AI, directed by a human.**
> Exporter is developed end-to-end with AI coding assistants; the developer acts as **creative director and QA**.
> `AGENTS.md`, `CLAUDE.md`, and `Project.md` are committed **on purpose** — this is a learning project. Read them, fork them, send PRs.

<br />

<p align="center">
  <img src="Docs/AppIcon-iOS-Default-512x512@1x.png" alt="Exporter icon" width="180" />
</p>

<h1 align="center">Exporter</h1>

<p align="center">
  A native, read-only iOS app that exports your authorized<br/>
  <b>Apple HealthKit</b> health &amp; fitness data into a versioned, LLM-friendly <b>JSON</b> schema.
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/iOS-26-000?logo=apple&logoColor=white" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" />
  <img alt="HealthKit" src="https://img.shields.io/badge/HealthKit-read--only-FF2D55?logo=apple&logoColor=white" />
  <img alt="design" src="https://img.shields.io/badge/Liquid%20Glass-iOS%2026-1B7CD5" />
  <img alt="license" src="https://img.shields.io/badge/license-GPL--3.0-success" />
</p>

---

## What is Exporter?

Exporter reads the HealthKit data **you authorize**, normalizes it into a single, versioned
JSON schema, and lets you either **preview / share it locally** or **POST it to a remote API
you configure**. It is **read-only** with respect to HealthKit — it never writes, never deletes.

It is a small, single-user app built for **personal / self-use** — **not** the App Store. Nothing
leaves your device except to the **primary or optional backup address you explicitly configure**: no accounts, no
telemetry, no third parties.

The exported JSON is designed to be compact and easy for both **humans and LLMs** to read: samples
are grouped by metric, column names and timestamps are hoisted out of every row, and sources are
deduplicated into an index table.

---

## ✨ Features

- 🩺 **Full HealthKit catalog** — a data-driven table of **~197 readable types** (120 quantity +
  69 category + 8 special: workouts, State of Mind, ECG, audiogram, GAD-7, PHQ-9, vision
  prescription, medication dose events) plus 6 personal **characteristics** (date of birth,
  biological sex, blood type, …). Adding a metric is one row in the registry.
- 🔐 **Read-only authorization** — requests `read` access only (`toShare: []`). Per-object types
  (vision prescription, medications) go through their own dedicated authorization flow. A denied
  read is indistinguishable from "no data", so all status wording stays conservative.
- 🧱 **Versioned JSON schema (v3)** — metrics grouped with a group-level `category`/`unit`, compact
  `columns`/`rows` (one sample per line), per-metric `extraColumns` for special types, an optional
  top-level `profile`, ISO-8601 dates, and a deduplicated `sources` index. Emitted by a custom
  string serializer (not `JSONEncoder`) for speed and exact layout control.
- ⏱️ **Two read modes** — **incremental** (`HKAnchoredObjectQuery` with a *deferred anchor commit*,
  so a cancelled export never advances your sync cursor) and a **specific date range**
  (`HKSampleQuery`).
- 📤 **Local or remote export** — share / copy the `.json` via `ShareLink`, or POST it to your
  endpoint with an optional `Authorization` header. With no endpoint configured, it degrades
  gracefully to local preview. Sending to a remote endpoint is always an explicit, confirmed action.
- ⚡ **Off the main thread** — data models, HealthKit queries, JSON encoding, and networking are
  `nonisolated` / `Sendable`; queries fan out with `withThrowingTaskGroup` (bounded window),
  encoding runs on a detached task. Large exports are streamed to a temp file — the UI only holds a
  summary plus a truncated preview, never the whole JSON string.
- 🪟 **Liquid Glass UI** — SwiftUI-first and HIG-compliant on iOS 26, with light/dark, Dynamic Type,
  and VoiceOver support.

---

## 🧾 The JSON (schema v3)

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

- Metrics are grouped; `category`/`unit` are hoisted to the group. `source` is an index into the
  top-level `sources` array. Time is `start` (ISO-8601) + integer `durationSec`.
- Special types carry extra columns — e.g. a `workout` adds `kcal`/`distanceKm`, an `ecg` adds
  `avgBPM`/`samplingHz`. Output ordering is deterministic and pinned by unit tests.

---

## 💻 Requirements

- **iPhone**, **iOS 26+** (deployment target 26.5).
- **Xcode 26** to build. macOS / watchOS / iPadOS are not targeted (HealthKit-on-iPhone only).

---

## 🛠 Build from source

```sh
git clone https://github.com/is52hertz/Exporter.git
cd Exporter
open Exporter/Exporter.xcodeproj      # open in Xcode 26, then ⌘R on a device
```

Or from the command line:

```sh
# Build (simulator)
xcodebuild -project Exporter/Exporter.xcodeproj -scheme Exporter \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Test (JSON serializer + metric-catalog unit tests)
xcodebuild test -project Exporter/Exporter.xcodeproj -scheme Exporter \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ExporterTests
```

> HealthKit returns almost no data on the Simulator, and authorization sheets need real taps —
> the authorization flow, real reads, and performance should be verified **on a device**.

---

## 🕵️ Privacy

Read-only with respect to HealthKit. No accounts, no analytics, no telemetry. Your health data
only goes to the addresses you save by tapping Done in Settings, when you send manually or opt into background
push. The primary must use HTTPS; the optional backup can use HTTP only for private or link-local
IP addresses and `.local` names. On HTTP, health data and the Authorization header are not encrypted;
use it only on a network you trust. For `.local` names, Exporter relies on the device's normal name
resolution and routing; the name itself does not authenticate the receiver. Try a manual send on
your local network first and allow local network access if iOS asks. The app only switches to the
backup if it can confirm no request reached the primary; it never follows redirects or switches
after an HTTP response. If the result is unconfirmed, check the receiver before resending. No
private APIs or arbitrary code execution.

---

## 🤖 AI-native development

This repo is a worked example of **AI-native development**. The context an assistant needs is
checked in **on purpose**:

| File | Purpose |
|---|---|
| `AGENTS.md` | **Source of truth** — product rules, coding standards, scope discipline, commit policy. |
| `CLAUDE.md` | Per-tool entrypoint (a symlink to `AGENTS.md`). |
| `Project.md` | Handoff doc — architecture, schema, decisions, platform gotchas. |

> Built with AI, directed by a human. Read the files, fork the repo, and study how it was made.

---

## 📜 License

Released under the **GNU General Public License v3.0** (GPL-3.0).

> Why GPL? This project exists to teach. GPL ensures that derivatives — including AI-generated
> forks — stay open so the next learner can study them too. If you build on it, share it back.

Copyright (C) 2026 Teethe. See [`LICENSE`](LICENSE) for the full text.
