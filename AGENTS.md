# Pocket Daily Agent Guide

This is the only project instruction file for every coding agent working in
this repository — Claude Code, Codex, OpenCode, and any model they drive (GLM
included). It holds the product constitution and the operational workflow.
Current, changeable state lives in `docs/PROJECT_MEMORY.md`.

## Instruction files and shared memory

- `AGENTS.md` is read natively by Codex, OpenCode, and Claude Code (2.1.277 or
  later). Do not add `CLAUDE.md`, `.claude/CLAUDE.md`, or `CLAUDE.local.md`
  here or in any parent directory: Claude Code reads those *instead of*
  `AGENTS.md`, so one stray file silently drops this guide for Claude.
- Keep this file portable plain Markdown. Refer to other documents by path;
  do not rely on tool-specific syntax such as `@path` imports, which only
  Claude Code expands. Keep it well under 32 KiB, Codex's default read limit.
- Put rules for a subtree in a nested `AGENTS.md` only when they apply solely
  there; the root file still applies.
- `docs/PROJECT_MEMORY.md` is the shared cross-session, cross-agent memory.
  Project facts, decisions, and hand-offs go there, never only into a
  tool-private memory (Claude auto memory, Codex or OpenCode state), which
  other agents cannot see. Private memory is for personal or per-machine notes.
- Personal preferences belong in each tool's user-level file
  (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`,
  `~/.config/opencode/AGENTS.md`), not in the repository.
- Tool-local state (`.claude/settings.local.json`, `.claude/worktrees/`,
  `.codex/`) stays untracked and never carries project decisions.

## Read in this order

1. This file, in full.
2. Only the task-relevant source and tests. Prefer `rg` and targeted reads; do
   not load the whole repository, and treat generated build output separately
   from source.
3. `docs/PROJECT_MEMORY.md` when the task depends on history, repository
   boundaries, release state, or hardware constraints.
4. For submission work, `APP_STORE_REVIEW.md` and `appstore/README.md`.
5. For live-studio or UI-pack work, `docs/LIVE_STUDIO_DESIGN.md` and the
   firmware contract `docs/live-studio-v1.md` in the sibling repository.

## Product identity

Pocket Daily is one universal App Store product with iOS, iPadOS, and macOS
targets. It is an account-free, distraction-free e-book reader that works on
its own, and the companion for X3/X4 readers running Pocket Daily or compatible
CrossPoint-based firmware. Both roles are first-class: reading must never
require a device, and the companion must never be demoted to a hidden extra.
The decision record and contracts are in `docs/READER_EXPANSION.md`.

The app is independent and is not affiliated with or endorsed by CrossPoint
Reader, Xteink, or a device manufacturer. Compatibility language must remain
precise. Do not imply that the app works with factory firmware or a
manufacturer cloud service.

## Core experience

- The Library and reader open first and work offline without hardware,
  accounts, or network. Books are DRM-free EPUB (TXT and Markdown are converted
  to EPUB on import); the library keeps book bytes unchanged so the file sent
  to a reader is the file read in the app.
- The reader imitates e-paper: instant page turns, minimal chrome, paper, white
  and night pages. Book scripts never run; the engine is the pinned foliate-js
  subset in `Support/ReaderEngine`, served only from the app's own URL scheme.
- Positions use KOReader XPointers plus overall progress, the format shared
  with X3/X4 firmware and KOReader. KOReader sync is optional and recommended;
  it contacts only the server the user chose and never moves the page without
  asking.
- Current-network discovery never changes the Apple device Wi-Fi. Bluetooth
  pairing and a temporary private Wi-Fi lease provide an explicitly selected
  direct connection that works without a router or internet.
- Compare the HTTP device ID with the paired identity when both are available.
  Legacy status responses lack a unique ID; do not claim cryptographic LAN
  authentication or automatic installation confirmation for unidentified readers.
- Transfers publish files atomically and expose useful progress and errors.
- macOS can also copy supported files atomically to a user-selected mounted SD
  card directory.
- Demo mode supports first-run exploration and App Review without a reader, but
  it must not mutate a device, join a network, or perform a transfer.
- Pocket Hub, AgentDeck, accounts, analytics, and infrastructure Wi-Fi are not
  prerequisites for the app. A KOReader sync account is an optional,
  user-chosen service, not a Pocket Daily account.
- Android is a future target: keep reading, sync, library, and transfer
  contracts platform-neutral and documented; do not start it without a product
  decision.

Shared behavior belongs under `Sources/` unless a platform constraint requires
a focused iOS or macOS implementation. Maintain a single coherent product
rather than treating the platforms as unrelated apps.

## Privacy and security

- Keep the app account-free and local-first.
- Do not add analytics, advertising SDKs, third-party tracking, or a cloud
  backend without an explicit product decision and corresponding privacy and
  App Store updates.
- Request Bluetooth, local-network, hotspot, location, and file permissions only
  when the related feature needs them, and explain their purpose accurately.
- macOS uses location only because nearby Wi-Fi discovery is platform-gated;
  Pocket Daily does not need or retain coordinates.
- Do not log secrets, passkeys, file contents, or unnecessary device-identifying
  data. Exported diagnostics must remain user initiated.
- Never commit signing identities, certificates, provisioning profiles, API
  keys, App Store Connect credentials, device passkeys, or captured private
  data.

## Firmware safety

Staging a firmware file is not installation. Validate supported firmware before
publication, explain compatibility and recovery implications, require explicit
acknowledgement, and preserve the reader's second confirmation before flashing.
Never introduce automatic flashing after transport completion.

## Repository map

- `Sources/`: SwiftUI app and shared iOS/macOS implementation.
- `Tests/`: deterministic protocol and parsing tests.
- `UITests/`: simulator UI tests that drive demo mode for the iPhone and iPad
  App Store screenshots (`scripts/capture_screenshots.sh`).
- `MacTests/`: renders the Mac App Store screenshots by hosting the shipping
  views in an off-screen window, so no Accessibility permission is needed.
- `Sources/Library`, `Sources/Reading`, `Sources/Sync`: the in-app library,
  reader bridge, and optional KOReader sync.
- `Support/`: entitlements and platform support files; `Support/ReaderEngine`
  holds the pinned reader engine (see its `SOURCE.json`).
- `project.yml`: XcodeGen source of truth.
- `Pocket.xcodeproj/`: generated and checked-in Xcode project.
- `appstore/`: App Store metadata, screenshots, and submission manifest.
- `docs/`: public privacy/support pages and durable project context.
- `scripts/`: icon generation and App Store package validation.

## App and firmware boundary

This repository owns Apple-platform UI, discovery and transfer clients, local
persistence, Xcode configuration, and App Store assets. The sibling repository
`pocket-daily-firmware` (next to this clone; GitHub
`puritysb/pocket-daily-firmware`) owns reader behavior, device endpoints,
on-device validation, and flashing. Resolve the sibling relative to this
checkout; absolute `~/github/` paths in older notes are stale.

Bluetooth records, endpoint payloads, paths, and update rules are contracts
between the two repositories. When a task changes one, identify the matching
firmware change and verify both sides explicitly; the change is not complete
until compatibility is checked and the contract is documented or tested. Do not
copy firmware source, binaries, secrets, or device-only build tooling into this
repository.

## Project generation

`project.yml` is authoritative for targets, settings, file membership,
capabilities, versions, and bundle identifiers. Never hand-edit
`Pocket.xcodeproj/project.pbxproj` or make a lasting change only there. After
changing `project.yml` or the source layout, run `xcodegen generate` (Homebrew
installs it at `/opt/homebrew/bin/xcodegen` if it is not on `PATH`) and keep
the specification and generated project in the same change.

The normal macOS App Store target stays sandboxed
(`Support/PocketMac.entitlements`). `Support/PocketMacDeveloperID.entitlements`
is only for explicit local hardware testing and must not replace it.

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
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
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
- Reading-position or sync changes: run `./scripts/e2e_sync.sh`, which starts
  the local KOSync test double (`scripts/kosync_dev_server.py`) and checks
  continuity from one simulator to another. The public KOReader server has
  outages; a local pass is not evidence of public-server behavior.
- Documentation-only changes: check links and run `git diff --check`.

Real Bluetooth pairing, temporary Wi-Fi association, local-network transfer,
mounted SD-card access, and TestFlight behavior require physical hardware and
must not be claimed as verified from simulator-only or local build results.

For hardware iteration the user prefers the reader's File Transfer → Join a
Network mode: the reader joins the home Wi-Fi, the firmware repository's
`scripts/pocket_put.py` pushes files over the same port-82 stream the app uses,
and `/api/status` verifies the installed version. Use that before asking for an
SD-card swap. The X3 STA profile has no mDNS; probe the LAN for `/api/status`.

## Swift conventions and quality bar

- Follow the existing SwiftUI structure and four-space indentation.
- Keep UI-observable state on the main actor and move blocking I/O off the main
  thread.
- Keep parsing and validation deterministic, with tests for valid, boundary,
  and malformed inputs. Fail safely on malformed or incompatible device data.
- Prefer explicit error handling; avoid force unwraps and silent catches.
  User-visible failures explain what happened and offer a recovery step.
- Preserve platform-specific behavior behind clear conditional compilation or
  focused abstractions; do not duplicate shared logic without a reason.
- Keep the demo path local and non-mutating.
- When behavior, privacy, compatibility, or release assumptions change, update
  the relevant source-of-truth document in the same change.

## App Store integrity

`project.yml`, `appstore/submission.json`, `appstore/README.md`,
`APP_STORE_REVIEW.md`, `PRIVACY.md`, and the checked-in screenshots/assets are
the release sources of truth. Metadata and review notes must describe behavior
that exists in the submitted binary. Screenshots must show real app UI.

Use manual release unless the release plan explicitly changes. Account-holder
actions—agreements, tax/banking, certificates, identifiers, App Store Connect
records, uploads, TestFlight review, submission, and release—require authorized
access and direct evidence. A successful local build or package validation is
not evidence of App Store submission or approval.

## Safety and repository hygiene

- Inspect `git status` before editing. Preserve unrelated user changes.
- Keep local agent settings and worktrees untracked.
- Do not submit a build, change App Store Connect state, publish a release,
  commit, or push unless the user explicitly asks for that external action.

## Durable memory

Update `docs/PROJECT_MEMORY.md` only for durable decisions, verified baselines,
cross-repository contracts, and hand-off facts likely to matter in future
sessions. Keep entries short, dated, and evidence-based; replace stale notes
instead of appending contradictions. Do not paste chat transcripts, transient
debugging logs, or firmware-only memories into it, and commit an entry together
with the change it describes so memory never gets ahead of the tree.
