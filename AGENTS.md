# AI Agent Instructions

This file is the single source of truth for all AI coding assistants working on this project.
Tool-specific files (`CLAUDE.md`) point here.

## Instruction Priority

- Treat this `AGENTS.md` as the authority for product requirements, business rules, coding standards, security/correctness constraints, verification expectations, commit policy, and handoff rules.
- Treat Trellis as the authority for task workflow mechanics: task lifecycle, phase order, PRD/research/spec-context handling, quality-gate sequence, session journal, and finish/archive steps.
- When these instructions and Trellis overlap, apply the more specific authority: product/business/code/security rules from `AGENTS.md`; task lifecycle and phase-flow rules from Trellis.
- Do not use Trellis text to weaken or bypass the business, security, correctness, or scope rules in this file.
- Do not use this file as a reason to skip required Trellis steps unless the current user message explicitly opts out for that turn.

## Product

`Exporter` is a native Apple app (Swift + SwiftUI, iPhone / iOS 26) that reads the user's authorized HealthKit health & fitness data, normalizes it into a versioned JSON schema, and either previews/shares it locally or POSTs it to a user-configured remote API. Bundle id: `cn.Teethe.Exporter`. Read-only with respect to HealthKit; personal/self-use, not App Store distribution.

## Project Phase

/

## Development Rules

### Scope Discipline
- Each task must stay within its stated scope. Do not add, refactor, or "improve" anything outside the current request.
- If the current task logically depends on another unbuilt feature, ask the user before implementing it. Never silently introduce adjacent functionality.

### Challenge & Confirm Before Building
- Uncertain changes (multiple approaches with tradeoffs, changes that may affect other features, or changes unsuited to the project's scale) must be confirmed with the user before modifying code.
- When there is a clearly optimal approach (security, efficiency), inform the user and proceed without waiting for confirmation.
- Push back on any request that compromises security, correctness, or runtime efficiency.

### Coding Standards
- **Layers & source of truth**: code lives under `Exporter/Exporter/` in layers `Health` (HealthKit access + `HealthMetric` type table), `Model` (`HealthSample`, `ExportEnvelope`), `Export` (`JSONExporter`, `ExportSender`/`HTTPSender`), `Store` (`AppSettings`, `AnchorStore`), `UI`. `ExportModel` (`@MainActor @Observable`) is the single source of UI state and flow; `AppSettings` (`@MainActor @Observable`) holds user config, persisted to `UserDefaults`. The Xcode project uses synchronized folders — new files under `Exporter/Exporter/` join the target automatically; never add source-file references to `project.pbxproj` by hand.
- **Concurrency**: default actor isolation is `MainActor` (Swift 5 language mode). Pure data, HealthKit queries, JSON encoding, and networking are `nonisolated` + `Sendable` and must run off the main thread (parallelize queries with `withThrowingTaskGroup`; encode via `Task.detached`). Every `@Observable` state mutation happens on the `MainActor` after an `await` — no main-thread blocking, no data races. `HealthKitManager` is a `@MainActor @Observable` class whose query/probe methods are `nonisolated`; its `healthStore` and `anchorStore` are `nonisolated let`. Target zero compiler warnings.
- **Data & JSON**: data models are `nonisolated` value types and must not import SwiftUI/UIKit. Encode through `JSONExporter` — a custom string-building serializer (schema v3: metrics grouped with group-level `category`/`unit`, compact `columns`/`rows` with one row per line, per-metric `extraColumns` for special types, optional top-level `profile`, ISO8601 dates, deduplicated `sources` index table, deterministic ordering). The exported shape carries `schemaVersion` so it can evolve; keep it stable. Optional object keys are omitted when absent; row cells may be `null` only for missing optional extras. Unit tests pin the format. Large exports are written to a temp file; UI holds only a summary plus a truncated preview snippet, never the full JSON string.
- **HealthKit**: read-only (`requestAuthorization(toShare: [], read:)`). The system authorization sheet appears only once — detect whether it would still appear with `getRequestStatusForAuthorization`; once determined, you can only deep-link the user to system Settings, not re-present it in-app. A denied read returns an empty result with no error and is indistinguishable from "no data" — any UI conveying read status must use conservative wording. Incremental reads use `HKAnchoredObjectQuery` with **deferred anchor commit**: never persist the new anchor inside the query; carry it back (archived as `Data` to stay `Sendable`) and commit only after the user confirms the export. Cancel and partial ("recent only") reads must not advance the anchor or `lastSyncDate`. Date-range reads use `HKSampleQuery`. The metric catalog is data-driven (`HealthMetric.registered`, ~197 entries generated from SDK headers); HK identifier strings are derived from `rawValue` with explicit exception cases (`VO2Max`, `UVExposure`, `AudioExposureEvent`) — a unit test resolves every entry. **Per-object-authorization types (vision prescription, medication dose events) must NEVER enter `requestAuthorization`/`getRequestStatusForAuthorization` read sets — HealthKit throws NSException (launch crash). Use `requestPerObjectReadAuthorization` (medications target `userAnnotatedMedicationType`) and tolerate per-metric query failures for these types.** Cap concurrent HK queries (window of 12 in `fetch`).
- **Export & send**: go through the `ExportSender` protocol; `HTTPSender` reads endpoint and optional `Authorization` header from `AppSettings`. With no endpoint configured, degrade to local preview/share without erroring. Sending data to a remote endpoint is an outbound action — confirm or follow explicit user instruction before doing it.
- **UI / HIG**: SwiftUI-first and HIG-compliant, using iOS 26 Liquid Glass. Prefer standard components and containers (they get glass automatically); apply `.buttonStyle(.glassProminent)` / `.glass` only on key controls. Do not hand-roll glass and do not stack glass on glass. A standard large-title navigation bar with a trailing toolbar button is the canonical title layout. Support light/dark, Dynamic Type, and VoiceOver.
- **Platform & permissions**: the app target is iOS only (`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"`); macOS has no HealthKit. The HealthKit usage string is injected via `INFOPLIST_KEY_NSHealthShareUsageDescription` (`GENERATE_INFOPLIST_FILE = YES`, no standalone Info.plist); the entitlement file is `Exporter/Exporter/Exporter.entitlements` (`com.apple.developer.healthkit`). Request authorization on demand from user action, never at launch.
- **Security boundary**: never add code that executes downloaded or arbitrary code, never use private APIs, and never expose user data beyond the single endpoint the user explicitly configured.
- **Verification commands**: build with `xcodebuild -scheme Exporter -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`; test with the same plus `test -only-testing:ExporterTests`. Note: Xcode's live "Cannot find type … in scope" errors are often stale cross-file SourceKit indexing — trust the `xcodebuild` result.

### Verify & Commit
- After any code change, run the project's verification (e.g. type-check / build / lint) across all affected packages.
- If verification fails, fix the errors first, then verify again.
- After verification passes, automatically commit files that were modified by the agent in the current task and belong to the current task.
- Before committing, inspect dirty files and separate current-task agent edits from unrecognized dirty files. Do not include unrecognized dirty files in commits unless the user explicitly asks to include them.
- If a dirty file's ownership or task relevance cannot be determined safely, stop and ask the user before committing.
- Group commits by coherent change unit. Do not push unless explicitly requested.
- Branching: per-feature work lands on a `feat/*` branch that merges into the mainline. Keep merged `feat/*` branches as historical archives — never delete them (local or remote).
- Commit message format (Conventional Commits):
  ```
  type(scope): short summary

  Detailed description of what changed and why.
  ```
  Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `ci`, `perf`.

### Session Handoff
- `notice.md` files are scoped by directory and record durable handoff information for the next agent.
- Root `notice.md` records global, cross-package, or cross-task project information.
- App/package notices record durable facts for that app/package: architecture, contracts, workflows, credentials, known limitations, and package-specific gotchas.
- Update the relevant `notice.md` only when the session creates or discovers information that remains useful beyond the current task or conversation. Do not record pure Q&A, routine progress, temporary decisions, or workflow session/journal details there.
- Ensure any `notice.md` you touch remains accurate and up-to-date within its directory scope.

### End-of-Session Summary
- At the end of each conversation, output a brief summary in 中文 (Chinese). This summary is user-facing.
  ```
  ## Summary
  - **Done**: work completed this round
  - **Key decisions**: tag each [user] or [self], explain the decision
  - **Commits**: list this round's commits (hash, message, files); note any dirty files left out and why
  - **Open/known risks**: issues introduced or discovered this round (omit if none)
  - **Suggested next steps**: 1-3 concrete actionable items
  ```
