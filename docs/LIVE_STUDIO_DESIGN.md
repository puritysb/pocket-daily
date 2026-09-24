# Pocket Daily Live Studio — application architecture and delivery design

STATUS: PARTIALLY IMPLEMENTED; design agreed 2026-09-19, audited 2026-09-22. The
firmware side of the contract (event protocol, `screen-live`, `.uipack`
format, host renderer) is `docs/live-studio-v1.md` in the sibling
`pocket-daily-firmware` repository. This document follows the shared
multi-agent conventions in `AGENTS.md`.

Goal: the app becomes a live studio for the reader — real-time device state,
an exact live preview of the reader screen, and a composer/editor for UI
packs that deploy over the existing verified transfer path and apply on the
device without reflashing.

## Why restructure

Current scope check: reducer/mirror, DeviceSession seam, live event client,
typed UI-pack encoder and model-driven apply/revert exist. The named target
directory layout and full session split below remain a design, not a completed
migration. `HostRendererBridge`, the pinned Apple artifact and renderer sync
script now exist for content cards. The editor has an offline reference preview
with bundled font, but connected-settings matching, other named native surfaces
and host/device pixel parity are not implemented. Content revision transactions and physical end-to-end acceptance
remain open in `IMPLEMENTATION_PLAN.md`. Passing protocol tests does not finish
the studio or prove radio reliability.

Host foundation update (2026-09-22): the sibling `test/gfx_host` target builds
the real rasterizer/font/shaping stack with a memory-display HAL and compares
Cached/BoundedUI text pixels locally. The independent library now powers the
app's actor-isolated content bridge through an imported host-only XCFramework.
The app exposes a labeled Base-layout content preview, not an exact mirror of
connected-reader settings. No device firmware
source/image was copied here; physical golden comparison remains pending.

The sibling now also shares ContentPageRenderer between its device theme and
host tests, plus ContentImageRenderer, with32 real-font text/card/empty/image
frame comparisons. Its host font storage now uses read-only immutable assets
bound per operation/thread, without the shared mutable fake-SD map or OS file
access. Context owners must retain assets and serialize each renderer. This
advances the common rendering boundary. The sibling now builds an independent
`libpdui_host.a` with a content-page C ABI and public Swift-importable header.
It owns copied font bytes, invalidates readback after failed renders and
serializes rendering across contexts for MiniBidi's static scratch. Its C ABI
matches24 direct page frames, and a macOS Swift executable renders/copies a
Korean empty state. The builder now packages all five Apple slices and verifies
source/artifact provenance. The app bridge now renders cards/empty pages, handles
failure/cancellation and converts physical bits into logical orientation.
Connected-configuration exact previews and physical device goldens remain pending.

Today `PocketModel` (≈990 lines) fuses session control, discovery,
heartbeat, transfer, preferences, demo mode, and UI state into one
`@MainActor ObservableObject`, and views bind the concrete class. Demo mode
and the value-driven `PocketDevicePreview` prove the UI can render from
synthetic state, but there is no seam for a second state source (a live
push channel), no frame history, and no place for a pack editor to live.
The restructure introduces that seam first and keeps every existing test
green while migrating.

## Target layout

The single-target, shared-sources structure stays (no SPM split before the
studio ships). Files move into layers:

```
Sources/
  App/         PocketApp, ContentView (studio shell, adaptive layout)
  Core/        DeviceSession, DeviceMirror, DeviceEvent reducers,
               DeviceState, PreviewStore, live policies
  Transport/   CrossPointClient, PocketStreamUploader, LiveSyncClient (WS),
               NearbySyncController, NearbySyncProtocol, HotspotJoiner,
               LocalReaderDiscovery
  Transfer/    TransferPreparation, TransferQueue, FirmwareImageValidator,
               firmware install check
  Studio/      StudioScene, PackEditorModel, PackDocument, HostRendererBridge,
               PackDeployer, PackLibrary
  Support/     PocketHardware, PocketPalette, shared UI components
```

`PocketModel` becomes a thin façade over `Core` + `Transport` during
migration and is deleted when the last view moves.

## Core: session, mirror, events

Operation-ownership implementation update (2026-09-22): PocketModel now uses one
token-owned work lane for file/content/theme operations, settings/preview, local
preparation/journal/SD work, discovery, manual verification, direct association
and session end. Connection replacement cancels and drains predecessor I/O and
cleanup before starting the latest request; backgrounding does not release an
in-flight OS join early. This removes the separate discovery/verification/join
task owners, but does not implement the full LiveDeviceSession/PreviewSession
split or move every view to the mirror. Physical acceptance remains pending.

- `DeviceSession` — the seam. A protocol describing capabilities the app
  needs: `statusStream`, `preferences`, `frames`, `transfers`,
  `packDeployment`. Two conformers: `LiveDeviceSession` (real device via
  `Transport`) and `PreviewSession` (host renderer / demo; no device). The
  protocol is intentionally small; transport details never leak above it.
- `DeviceMirror` — the single observable object views bind. It holds an
  immutable `DeviceState` snapshot and applies `DeviceEvent`s through pure
  reducer functions (`func apply(_ e: DeviceEvent, to: DeviceState)`), which
  makes event handling unit-testable without a device.
- `DeviceEvent` — `.status(CrossPointStatus)`, `.frame(seq, data)`,
  `.preferences(ReaderPreferences)`, `.transferProgress(…)`,
  `.connection(ConnectionPhase)`, `.packStateChanged(…)`.
- `PreviewStore` — ring buffer of recent frames (seq, timestamp, BMP data)
  powering the live canvas, history scrubber, and side-by-side compare.
- Live policies are pure and tested, mirroring `ReaderDiagnosticsPolicy`:
  `FrameFetchPolicy` (subscription cadence, staleness), `SyncModePolicy`
  (push vs. poll from `/api/status` `liveStudio` advertisement).

## LiveSyncClient

Dedicated-session update (2026-09-24): COMPANION and POCKET_SYNC now both
advertise poll-only and suppress automatic diagnostic/frame downloads. The app
honors the existing advertisement without a new wire format. Same-Wi-Fi push
remains a browser/File Transfer option, not a Pocket Sync requirement. See
[SYNC_SESSIONS.md](SYNC_SESSIONS.md) for routes and physical acceptance gates.

Current-memory admission (2026-09-23): an advertised push listener is not enough
to open the optional WebSocket. The app requires at least16 KiB in the current
HTTP status, matching the firmware listener admission floor. Below it, status
uses the existing paced heartbeat and no frame subscription is opened. This
addresses stale pre-listener admission, not a proven fix for the observed
partial HTTP responses or radio loss; physical acceptance remains required.

Implementation update (2026-09-21): bulk transfers now own the reader link.
Frame fetches, preference reloads and heartbeats are cancelled and drained
before upload; optional sync returns after commit/apply via a fresh heartbeat.
Frame scheduling retains the newest announcement and explicitly wakes after
the spacing deadline, even if no further event arrives. Session generations
reject late results from a previous connection. A stopped WS transport can be
recreated on the next successful heartbeat.

The upload client's optional `uploadStreamWindow:4096` negotiation mirrors the
sibling firmware contract: each 4 KiB block waits for an SD-accepted ACK before
the next is sent. Legacy readers retain the original stream. Recovery uses
bounded, paced LAN status probes and identity checks, not just private-AP
reassociation. Physical heap/radio validation remains separate from loopback
and simulator tests.

- WebSocket client for the reader's live-studio listener; connects when
  `/api/status` advertises `liveStudio.wsPort` and `SyncModePolicy` selects
  push. Frame notifications trigger chunked HTTP fetch of
  `/api/pocket/v1/screen-live` — the same paged octet-stream pattern the
  app already uses for `screen-preview`.
- Private AP or legacy readers: no live WS; the current app uses a paced
  15-second heartbeat, not the earlier draft's 2-second polling. One-second
  frame-fetch spacing is separate from heartbeat cadence. Backgrounding stops
  optional traffic; foreground restores monitoring of an existing LAN session
  without automatic Wi-Fi joining or file resending.
- The unused `HotspotLease.webSocketPort` parsing remains but the studio
  never assumes a fixed port.

Firmware capture guard (2026-09-22): failed or pending live-content renders do
not publish a new frame. The previous valid capture may remain available as
history; it must not be treated as confirmation of a new content revision.
Content Apply uses the separate identity/revision/generation-bound presentation
receipt, not a frame event, to report driver completion. Wire formats are
unchanged. Physical pixels and host/device parity remain unverified.

## Studio UX

Content live editing update (2026-09-22): the card editor has an explicit,
non-persistent Start live apply authorization for one reader/connection session.
It coalesces valid edits and awaits the existing activation plus redraw receipt
before processing the newest edit. Failure, editor closure, backgrounding or
session replacement stops automation. This is content-only; the theme-pack
manual deployment contract below and firmware installation confirmation remain
unchanged. See CONTENT_EDITOR.md. Physical acceptance remains pending.

```
┌───────────────────────────────┬──────────────────────┐
│  Canvas: exact 1-bit reader   │  Editors             │
│  frame in device chassis      │  - Theme metrics     │
│  (live device | host preview  │    (grouped, bound   │
│  | side-by-side compare)      │     to pack doc)     │
│  history scrubber below       │  - Strings           │
├───────────────────────────────┤  - Fonts (assets)    │
│  Deploy bar: pack name/version│  - Device state      │
│  target ▾ · Apply live ·      │    inspector         │
│  Revert · Save .uipack        │                      │
└───────────────────────────────┴──────────────────────┘
```

- **Live device mode** — frames from `PreviewStore`; connection phase and
  frame staleness are explicit, never fabricated (extends the existing
  "preview unavailable" contract).
- **Host preview mode** — `HostRendererBridge` renders the pack through the
  firmware host renderer; works offline and in demo mode. This is the
  edit loop; the device frame is ground truth for verification.
- **Compare mode** — host render and latest device frame side by side; the
  mismatch banner is the drift signal (with golden tests as the hard gate).
- Demo mode stays local and non-mutating; the studio renders in host
  preview mode with a synthetic device state.

## HostRendererBridge

Links `Support/PocketUIHost/PocketUIHost.xcframework`, built by sibling
`host/build_apple.py` for macOS arm64/x86_64, iOS arm64 and simulator arm64/x86_64.
The app's `scripts/sync_host_renderer.sh` verifies/copies the package
and `PROVENANCE.json`, pinning both commit and actual dirty-tree source/artifact
hashes plus SDK/build metadata — the documented cross-repo artifact exception.
A Swift actor owns the C ABI context and renders content cards/empty pages to
physical1-bit frames with logical image conversion. UI-pack apply and the named
native surfaces are not yet exposed. The content editor renders an offline
reference preview with a pinned PocketSansWorld font and explicit default labels.
When the artifact is missing or its pinned provenance does not match the
accepted renderer version, the bridge reports "host preview unavailable" instead of
silently degrading.

Packaging verification compares the actual sibling source manifest, including
uncommitted/untracked dependencies, not only HEAD. The sibling builder links an
actual Swift consumer for all five architecture/platform slices. App tests now
execute the bridge on the iOS simulator; this is not physical iOS/reader
acceptance. Runtime verification uses bundled PIN/provenance plus ABI version;
the sandboxed pre-build gate checks static artifact hashes. It never depends
on a sibling checkout existing on an end user's device. See `HOST_RENDERER.md`.
The import/packaging work does not turn provenance hashes into authentication.

## PackDocument / PackDeployer

Current editor boundary (2026-09-22): the existing eight-metric inspector can
be expanded and edited offline, including demo mode. Apply/Revert alone require
UI-pack capability, a nonempty reader identity and an idle non-demo session.
Values are explicitly labeled local defaults/edits, not a readback of the
active device pack. The eight-metric draft now has explicit actor-isolated local
Save/reload, conflict checks and a storage-free demo model (`THEME_DRAFT.md`).
Portable eight-metric JSON import/export also exists: bounded validation,
current/imported comparison and explicit in-memory replacement precede separate
Save/Apply actions. It is not a binary `.uipack` or a resource/font document.
This does not implement the complete PackDocument with resources, pack
import/export, or UI-pack host preview below. Activation and screen confirmation
remain separate; editing never calls a transport method.

- `PackDocument` is the editable model (theme overrides keyed by the stable
  field-id registry, string overrides, font assets). Serialization follows
  the `.uipack` binary format from the firmware contract; the encoder lives
  behind a protocol so tests round-trip it without a device.
- `PackDeployer` reuses the verified transfer machinery — stage in
  Application Support, port-82 stream upload with resume, CRC commit — then
  calls the apply endpoint and confirms the result from `liveStudio`
  advertisement in `/api/status`. Revert uses the same path with an empty
  pack name. Deployment is never automatic and never touches firmware
  images.

## Migration plan (keeps tests green)

1. Introduce `Core` types and `DeviceSession`; `PocketModel` conforms and
   publishes through a `DeviceMirror` alongside its existing fields. Views
   keep working unchanged. Unit tests for reducers land here.
2. Move views from `PocketModel` to `DeviceMirror` in small groups
   (inspectors first, studio surfaces last); port the 44 existing unit
   tests as the binding surface moves.
3. Add `LiveSyncClient` + `PreviewStore` (polling first, WS when firmware
   LS-1 ships), then `Studio/` behind a feature flag.
4. Delete the `PocketModel` façade when no view references it.

## Verification expectations

Per `AGENTS.md`, every phase verifies both sides of any contract change:

- Pure logic (reducers, policies, pack encode/round-trip, WS event
  codecs): deterministic unit tests in `Tests/`.
- Transport: extend the loopback fake-reader tests to script WS events and
  `screen-live` paging.
- UI: demo-mode studio snapshots through the existing screenshot pipeline;
  first-run no-prompt regression stays pinned.
- Cross-repo parity: golden-image comparison host vs. device per the
  firmware contract; hardware X3 transfer/capture sign-off recorded in
  `docs/CONNECTIVITY_VALIDATION.md`.
- App Store material is refreshed only when studio features are user-
  visible in a shipping build; design docs describing unshipped behavior
  never feed App Store metadata.

## Phases (mirroring firmware LS-1..LS-4)

- **M1** — `Core` restructure + polling mirror + connection UX unchanged.
  Acceptance: all existing tests green against the new seam; no behavior
  change.
- **M2** — live frames (`PreviewStore`, canvas, history). Acceptance:
  live capture on X3 over STA for a reading session without watchdog
  resets; fallback states on private AP/legacy.
- **M3** — pack editor + host preview + deployment. Acceptance: edit →
  apply → device reflects the pack without reflashing; revert works; goldens
  match.
- **M4 (conditional)** — firmware flash diet (builtin fonts to SD) if the
  firmware side needs headroom; app side only repackages SD bundle assets.

## Risks

- Renderer drift (host vs. device) — mitigated by golden tests + compare
  mode; the device frame always wins as ground truth.
- Swift↔C++ artifact friction — the C ABI is deliberately tiny; the bridge
  fails loudly when provenance does not match.
- Private-AP heap — push features are STA-first by policy, not by
  afterthought.
- Scope creep into reader rendering — explicitly out of scope; the editor
  only edits chrome metrics/strings/fonts.
