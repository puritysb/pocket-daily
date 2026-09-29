# Local content renderer integration

`HostRendererBridge` calls the sibling firmware's production content renderer
through the accepted host-only XCFramework. It does not contact a reader, stage
files, activate content, change Wi-Fi or update firmware. The content editor
exposes an offline content-page preview using an explicitly labeled reference
configuration, not the connected reader's settings or captured screen.

## Import and build

Build the sibling with `python3 host/build_apple.py`, then use its reported output:

```sh
bash scripts/sync_host_renderer.sh ../pocket-daily-firmware/build/apple-host-<id>
python3 scripts/host_renderer_artifact.py verify Support/PocketUIHost
python3 scripts/test_host_renderer_artifact.py
xcodegen generate
```

Only `PocketUIHost.xcframework`, public C headers/module map and provenance are
imported, using the approved host-artifact exception. No device image, source
tree is copied. Font assets are imported separately as described below.
Import verifies the sibling source/commit and artifact
hashes before and after copying. Updates preserve the previous verified artifact
under `.build/host-renderer-backups/`; identical imports are no-ops. A changed
existing artifact is refused rather than silently overwritten.

`PIN.json` records the accepted source/artifact hashes and ABI. Every iOS/macOS
build verifies the package against that pin with a sandboxed pre-build script.
`RendererInputs.xcfilelist` grants only the necessary package/metadata reads;
script sandboxing remains enabled. `project.yml` owns the static XCFramework,
C++/zlib link dependencies and bundled metadata; regenerate the Xcode project
after source-layout/configuration changes. A checkout with the accepted artifact
builds without a sibling repository. Importing a new artifact requires it.

Runtime checks compare bundled PIN/provenance and the native ABI version.
Static-library file hashes are checked at build time, not recomputed against
the app executable at runtime. End-user devices never need the sibling checkout.
These checks establish integrity/version agreement, not sender authentication.

### CrossPoint 1.6.5 integration refresh — 2026-09-30

The accepted package is built from sibling firmware commit `ee188fe7`
(`build/apple-host-nx6umpg9`), after its CrossPoint 1.6.5 integration. The source
digest is `671f5c1c31f91ab3cc5928dcec3fd2bbc80da57c34afd27ac6c485bce904e7c9`;
the artifact digest is `6f7dd0b1871876b28af94753adb032153a06c95ba790b519f2f855ffc0e8f6dc`.
Its source inventory includes the FreeInk SDK headers/font allocator used by
the host build. The public C header, ABI 1 and package file layout are unchanged.
The shared Home painter now includes the Articles action inside Pocket Reader.
Existing Swift integration, font assets and transport contracts are preserved.
The importer retains the prior package under `.build/host-renderer-backups/`.
This updates offline previews; it neither changes nor installs device firmware.

## Calling the bridge

The earlier `apple-host-0pvcfof1` package added PDCT v2 card layouts through the
unchanged ABI1 document argument. Text-first v1 remains byte-compatible; image
first and side-by-side use the same decoder and renderer as the device.48
real-font mode comparisons and40 direct/C-ABI page comparisons cover both
geometries/all rotations. Swift additionally verifies distinct layout pixels
and exact restoration of the default. See sibling content-card-layout-v2.md.

Provide a validated cpfont (up to64MiB), hardware profile, orientation, card,
optional PBM and explicit localized labels/layout metrics. The bridge owns no
network session. Actor isolation handles font creation, metadata reads, native
calls and context destruction; native drawing is additionally serialized across
contexts for CrossPoint's shared bidi scratch. Font and metadata loading are
deferred until an actor-isolated request, not performed on the UI initializer.

Cards use the shipping `ContentCard.encoded()` contract. Successful results are
immutable physical1-bit frames; `Frame.image()` maps them to logical display
coordinates without interpolation. Failed/cancelled requests throw and return
no frame. Callers must discard stale UI results using their editor generation
and must not label an older frame as the current edit. A fresh explicit request
can recover from native failure; there is no automatic upload or retry loop.

## Home and Daily Brief layout previews (P1-3)

The same artifact exports `pdui_render_home` and `pdui_render_brief` (additive
to ABI 1). They take a `pdui_profile` with the firmware record IDs (Home items
1 reading, 2 study, 3 provider, 4 monitor; weather 0 bottom, 1 top, 2 off;
sleep mode 0 brief, 1 reader; sections 1 reading, 2 study, 3 weather, 4 today)
and a `PDUI_SAMPLE_*` mask selecting built-in sample content. The device and
host share `src/pocket_daily/home/HomeRenderer` in the sibling repository;
only the header, book cover and fonts are host stand-ins. The bridge converts
`PocketProfile` with `nativeProfile(_:)` and rejects invalid profiles before
native code. `LayoutPreviewModel` renders off the main actor and keeps the
previous frame until the new one is ready. These previews are not device
receipts; pixel comparison with a reader capture is pending.

## Offline editor preview

`ContentCardPreview` renders the selected draft card (or empty page), including
its stored PBM, for X3/X4 and four orientations. `ContentPreviewModel` debounces
edits and clears obsolete pixels immediately; a generation guard discards late
results after another edit or closing the view. Invalid drafts show an error,
never an older frame labeled as the current edit. Drawing and file reads stay
off the main actor. This path has no transfer or firmware-update dependency.

`Support/PreviewFont` bundles the existing PocketSansWorld 12 px cpfont from
the sibling assets, with its README and four OFL notices. The one-time
`python3 scripts/sync_preview_font.py` importer checks a pinned size/SHA-256 and
refuses to overwrite an existing import. `PreviewFontStore` independently
checks the manifest and bytes off the main actor before caching the font.
The editor exposes the bundled notices. No font generation or download occurs.

The reference uses Base layout metrics and English, unremapped button labels.
Exact comparison requires matching device font bytes, metrics, labels, input
mapping and orientation. Connected-reader configuration matching, other native
theme surfaces, UI-pack application through the ABI and physical device pixel
comparison remain pending. Do not treat the offline preview as a device receipt.

## UI verification

The screenshot script accepts exact simulator UDIDs in
`POCKET_IPHONE_SIMULATOR` and `POCKET_IPAD_SIMULATOR`, as well as model names.
Use exact IDs when multiple installed runtimes share a model name. An optional
`POCKET_SCREENSHOT_DERIVED_DATA` selects an isolated build directory (normally
under `.build/`). Failed runs retain their temporary result bundles and report
the location; success cleans the temporary exports after publishing screenshots.
Do not treat a runner's diagnostic-collection phase as a completed test result.

## Glyph-fallback font (2026-09-27)

`HostRendererBridge` installs the bundled PocketSymbols font with
`pdui_set_fallback_font` (firmware `75df8f0e`), so previews draw emoji and
symbols the preview font lacks, as the reader does once the font is installed.
The preview font then loads in Cached mode, the mode of the reader's normal
Home/Sleep screens; without a fallback it stays in BoundedUI. For covered text
the two modes differ by about one pixel row at the top of bold Hangul (under
200 bits per X3 card page); `HostRendererBridgeTests` bounds that difference.
