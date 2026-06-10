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

/

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
- **Source of truth & persistence**: `AppModel` (`@MainActor @Observable`) is the single in-memory source of truth. Persist as Codable JSON in Application Support (atomic write, debounced save). Data models are `nonisolated` Codable value types and must not import AppKit/SwiftUI. Keep persisted formats independent of third-party libraries (e.g. store Carbon key codes, not a library's internal type).
- **Concurrency**: default actor isolation is `MainActor` (Swift 5 language mode). Types touching AppKit/SwiftUI stay on `MainActor`; `AppModel` and services must stay free of AppKit/SwiftUI so they remain unit-testable. Inject services via the composition root (`AppController`); do not use singletons.
- **Global hotkeys**: register only the active Profile, via the `KeyboardShortcuts` package. Never use `CGEventTap` or global `NSEvent` monitors — they require Accessibility / Input Monitoring and are out of scope.
- **Controlling other apps**: prefer public AppKit APIs — `NSWorkspace.openApplication`, `NSRunningApplication.hide/unhide`. From this background agent, bring an app forward with `openApplication(at: bundleURL)`, not `NSRunningApplication.activate(from: .current)` (cooperative activation silently fails for a non-frontmost agent). No private APIs.
- **UI**: SwiftUI-first; bridge to AppKit only when required. The management UI must live in a `Window`, not the `Settings` scene (Settings drops custom toolbars). Use system controls, HIG spacing, light/dark, and full keyboard + VoiceOver. Rely on automatic Liquid Glass from standard containers on macOS 26.5 — do not hand-roll glass. Prefer modern surfaces (`.popover`) over the legacy `.help` tooltip for essential information.
- **Permissions**: functionality takes priority over avoiding permissions. Permission-gated capabilities (e.g. Accessibility, used to minimize a target window) are allowed when they are the way to implement a feature — provided the permission is requested **lazily / on demand** (when the user opts into that feature, or first triggers it), **never at launch**. The app must stay fully functional without the permission; only the gated capability degrades, and it degrades safely (do nothing destructive + surface a one-time notice — never silently do the wrong thing). Note: Accessibility grants app-level access, not a per-feature scope. Global hotkeys still go through `KeyboardShortcuts` (no `CGEventTap` / global `NSEvent` monitors needed).
- **Security boundary**: the app is un-sandboxed and can launch/activate arbitrary apps. Never add code that executes downloaded or arbitrary code, never use private APIs (only documented public AppKit + Accessibility attributes), and never expose any control surface beyond the local user's own machine.

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

