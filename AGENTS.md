# Pocket Daily Agent Guide

This file is the shared entry point for Codex, Claude, and other coding agents
working in this repository. Keep it operational and concise. Product invariants
live in `CLAUDE.md`; durable hand-off context lives in
`docs/PROJECT_MEMORY.md`.

## Read in this order

1. Read this file for workflow and verification requirements.
2. Read `CLAUDE.md` before changing product behavior, architecture, privacy,
   firmware flows, or App Store material.
3. Read only the task-relevant source and tests.
4. Read `docs/PROJECT_MEMORY.md` when the task depends on project history,
   repository boundaries, release state, or known hardware constraints.
5. For submission work, read `APP_STORE_REVIEW.md` and `appstore/README.md`.

Do not load the whole repository by default. Prefer `rg` and targeted file
reads, and treat source code and generated build output as different concerns.

## Repository map

- `Sources/`: SwiftUI app and shared iOS/macOS implementation.
- `Tests/`: deterministic protocol and parsing tests.
- `UITests/`: simulator UI tests that drive demo mode for the iPhone and iPad
  App Store screenshots (`scripts/capture_screenshots.sh`).
- `MacTests/`: renders the Mac App Store screenshots by hosting the shipping
  views in an off-screen window, so no Accessibility permission is needed.
- `Support/`: entitlements and platform support files.
- `project.yml`: XcodeGen source of truth.
- `Pocket.xcodeproj/`: generated and checked-in Xcode project.
- `appstore/`: App Store metadata, screenshots, and submission manifest.
- `docs/`: public privacy/support pages and durable project context.
- `scripts/`: icon generation and App Store package validation.

## Repository boundary

This repository owns the iOS, iPadOS, and macOS companion app. The reader
firmware is a separate project at the sibling path
`/Users/puritysb/github/pocket-daily-firmware` and GitHub repository
`puritysb/pocket-daily-firmware`.

Do not copy firmware source, binaries, secrets, or device-only build tooling
into this repository. When a task changes a Bluetooth record, HTTP endpoint,
file layout, or firmware-update contract, identify the matching firmware change
and verify both sides explicitly. Do not silently invent protocol behavior in
only one repository.

## Project generation

`project.yml` is the source of truth for targets, settings, file membership,
capabilities, versions, and bundle identifiers. Do not hand-edit
`Pocket.xcodeproj/project.pbxproj`. After changing `project.yml` or the source
layout, run `xcodegen generate` and keep the specification and generated project
in the same change.

## Build and verification

Run the smallest relevant checks while iterating, then the full affected set
before handing off. Keep derived data under `.build/` so it remains local.

```sh
xcodegen generate

xcodebuild build \
  -project Pocket.xcodeproj \
  -scheme Pocket \
  -sdk iphonesimulator \
  -derivedDataPath .build/ios \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project Pocket.xcodeproj \
  -scheme Pocket \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  -derivedDataPath .build/tests \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project Pocket.xcodeproj \
  -scheme PocketMac \
  -sdk macosx \
  -derivedDataPath .build/mac \
  CODE_SIGNING_ALLOWED=NO

./scripts/validate_app_store.sh
```

Use `xcrun simctl list devices available` and substitute an available simulator
name and OS when the example runtime is not installed. Verification
expectations:

- Swift or protocol changes: relevant tests plus both affected platform builds.
- `project.yml`, entitlements, or file-membership changes: regenerate, inspect
  the project diff, and build every affected target.
- User-facing UI changes: regenerate the screenshot set with
  `./scripts/capture_screenshots.sh`, which needs no special permissions.
- App Store metadata, screenshots, icons, privacy, or support changes: run
  `./scripts/validate_app_store.sh` and inspect the changed artifacts.
- Documentation-only changes: check links and run `git diff --check`.

Real Bluetooth pairing, temporary Wi-Fi association, local-network transfer,
mounted SD-card access, and TestFlight behavior require physical hardware and
must not be claimed as verified from simulator-only results.

For hardware iteration the user prefers the reader's File Transfer → Join a
Network mode: the reader joins the home Wi-Fi, the firmware repository's
`scripts/pocket_put.py` pushes files over the same port-82 stream the app uses,
and `/api/status` verifies the installed version. Use that before asking for an
SD-card swap. The X3 STA profile has no mDNS; probe the LAN for `/api/status`.

## Swift conventions

- Follow the existing SwiftUI structure and four-space indentation.
- Keep UI-observable state on the main actor and move blocking I/O off the main
  thread.
- Prefer explicit error handling and actionable user-facing failures. Avoid
  force unwraps and silent catches.
- Keep protocol parsing deterministic and add tests for valid, boundary, and
  malformed inputs.
- Preserve platform-specific behavior behind clear conditional compilation or
  focused abstractions; do not duplicate shared logic without a reason.
- Keep the demo path local and non-mutating.

## Safety and repository hygiene

- Inspect `git status` before editing. Preserve unrelated user changes.
- Never commit credentials, signing certificates, provisioning profiles,
  App Store Connect secrets, device passkeys, or captured private data.
- Keep local agent settings and worktrees untracked.
- Do not submit a build, change App Store Connect state, publish a release,
  commit, or push unless the user explicitly asks for that external action.
- A successful local build or package validation is not evidence of App Store
  submission or approval.

## Durable memory

Update `docs/PROJECT_MEMORY.md` only for durable decisions, verified baselines,
cross-repository contracts, and hand-off facts likely to matter in future
sessions. Keep it short, dated, and evidence-based. Do not paste chat
transcripts, transient debugging logs, or firmware-only memories into it.
