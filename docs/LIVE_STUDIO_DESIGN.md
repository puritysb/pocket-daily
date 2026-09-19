# Pocket Daily Live Studio — application architecture and delivery design

STATUS: DESIGN, agreed 2026-09-19. Nothing here is implemented yet. The
firmware side of the contract (event protocol, `screen-live`, `.uipack`
format, host renderer) is `docs/live-studio-v1.md` in the sibling
`pocket-daily-firmware` repository. This document follows the shared
multi-agent conventions in `AGENTS.md`.

Goal: the app becomes a live studio for the reader — real-time device state,
an exact live preview of the reader screen, and a composer/editor for UI
packs that deploy over the existing verified transfer path and apply on the
device without reflashing.

## Why restructure

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

- WebSocket client for the reader's live-studio listener; connects when
  `/api/status` advertises `liveStudio.wsPort` and `SyncModePolicy` selects
  push. Frame notifications trigger chunked HTTP fetch of
  `/api/pocket/v1/screen-live` — the same paged octet-stream pattern the
  app already uses for `screen-preview`.
- Private AP or legacy readers: no WS; the mirror falls back to today's
  heartbeat cadence (2 s while studio is active).
- The unused `HotspotLease.webSocketPort` parsing remains but the studio
  never assumes a fixed port.

## Studio UX

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

Links `Support/PocketUIHost/libpdui_host.a` (copied by
`scripts/sync_host_renderer.sh` from the sibling firmware checkout, with
`PROVENANCE.txt` pinning the firmware SHA — the documented cross-repo
artifact exception in the firmware contract). A small Swift wrapper owns
the C ABI context, applies pack bytes, renders named surfaces, and returns
a 1-bit buffer the existing `EInkSurface` path can display unchanged.
When the artifact is missing or the provenance SHA does not match the
sibling checkout, the bridge reports "host preview unavailable" instead of
silently degrading.

## PackDocument / PackDeployer

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
