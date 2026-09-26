# Local content authoring

Card layout extension (2026-09-22): the editor offers Text first, Image first
and Side by side for each card. Layout travels in the immutable card revision
and through the same production renderer for offline preview and device drawing.
Nondefault layouts use PDCT v2 and require reader capability4 before staging;
default cards retain exact v1 output. Nondefault drafts save as schema2, which
older apps reject; old schema1 drafts default to Text first. Layout changes
alone reuse verified unchanged images. Missing images use ordinary text flow.
See sibling `docs/content-card-layout-v2.md` for geometry and golden fixtures.
This is a card-detail extension, not the complete multi-surface UI editor.

`ContentDraft` contains up to three editable cards and their image data.
`ContentDraftStore` persists a schema1 JSON record under Application Support /
Pocket / Studio / content-draft.json. The app should own one store actor and
share it among its editor windows. File I/O is isolated away from the main actor.

Draft storage deliberately accepts incomplete card text. Storage bounds (4096
UTF-8 bytes per text field, at most16 images, 256KiB image payload, 512KiB encoded
record) are not the firmware's publishing limits. `deploymentSnapshot()` builds
an immutable ContentRevision and performs the stricter PDCT/PDCM/image/reference
validation. Saving a draft never opens a network connection or activates content.

Writes use atomic replacement. Each successful changed save increments a
generation; a stale expected generation is rejected. Unchanged saves do not
rewrite the file. Loading distinguishes missing files from corrupt, oversized,
unsupported-schema or unreadable data. Save refuses to replace such files
implicitly. The generation guard is for a single shared actor, not a cross-process
lock or a guarantee against external concurrent file modification.

`ContentEditorModel` publishes the editable draft, dirty/busy state and errors.
Loading refuses to discard unsaved changes, including edits made during a load.
Saving retains any edits made while persistence was suspended; only the saved
snapshot becomes the clean baseline. Concurrent model operations are rejected.
Store conflicts keep the in-memory edits and report an actionable error.

## Explicit recovery

A failed load or save can be recovered only after a separate confirmation.
Recovery validates the chosen in-memory draft first, then copies the current
regular file byte-for-byte to a unique `content-draft-backup-<UUID>.json` sibling
before atomically publishing the replacement. It does not decode or truncate
the backup, so corrupt, oversized and unknown-schema drafts can be preserved.
Copy/permission/non-file failures stop replacement. Publication failure retains
the backup and reports its location. No old backup is automatically deleted.
The editor exposes the latest backup filename and an explicit export action.
If no draft loaded, recovery begins with an empty draft; unsaved in-memory edits
otherwise remain the chosen draft. Recovery never deploys to a reader.

Recovered records carry an optional UUID `recoveryID`; ordinary old schema1
records decode with no recovery ID. Save compares both generation and recovery
ID, preventing pre-recovery editors from overwriting a new generation1 record.
This is a same-version, shared-actor conflict guard, not a cross-process lock or
protection against an older app which ignores the additional field. Backup
comparison/import and persistent backup browsing are not yet implemented.

## Studio layout (all platforms, 2026-09-25)

One studio serves Mac, iPad and iPhone (`ContentView`, `StudioSection`):
**Home & Sleep** holds everything the reader shows from Pocket Daily (Home
items, **My cards**, weather, sleep screen, and the reader settings "Open
Pocket Daily when the reader starts", book cover, sleep timeout and text size)
with one Send. The **Reader** inspector holds the connection, files ("Write
text to read" makes a .txt), troubleshooting (folded) and About & Privacy.
Wide windows (at least 920 pt) show the header with the reader state beside a
320 pt inspector; the canvas stays in view while the controls scroll, and
stacks above them below 720 pt of studio width. Narrower windows (iPhone,
iPad split view) use two tabs. Removed in the same change: the Cards tab (now
My cards), the theme-metric inspector, the reader-screen capture download and
live-frame fetching (no view showed them), the LIVE/POLL badge, JSON card
import/export and Auto-send.

Send (`PocketModel.sendReaderLayout`) posts the profile and reader settings in
one reader work item, only the parts that changed, then applies My cards
through the content lane when their revision differs from the reader's
(`readerContentRevision`, read once per connection). Revert restores the
profile and settings last loaded; cards are local drafts (Load from reader
restores them).

## My cards (2026-09-25)

Up to three pages (`MyCardsEditor`): title, text, note and an optional 1-bit
image. The image menu makes a QR code from text or a link on the device
(`ContentQRCode`: CoreImage, error correction M, 4-module quiet zone,
whole-pixel modules within 240 px because the reader never enlarges images),
fetches an image from an HTTPS link (`ContentImageImport.load(remote:)`:
no cookies or cache, 20 MB, image types only), or converts a chosen file.
Editing a card shows the Card surface (the page as opened on the reader);
Home and Sleep previews draw the user's cards through `pdui_set_cards`.
Profile item `word` (daily word as its own page) and sleep section `card`
(first card with its image, always shown) are offered when the reader
advertises them.

## Card studio (2026-09-24; history, now My cards)

The card editor was a studio surface (`ContentStudioView`). The canvas is the
connected hardware chassis showing the exact host-rendered reader frame for
the selected card (`PocketDevicePreview.renderedScreen`); layout and preview
orientation sit above it, card chips and Add below, and the selected card's
fields beside it (below it when stacked).

- One content action: **Send to reader** (Command-Return). It calls the same
  exclusive `applyContent` lane with no confirmation dialog. Every send
  refreshes e-ink, so sending is never automatic by default.
- **Auto-send** is an opt-in toggle for the current reader session only; it is
  the existing coalescing live apply without its confirmation dialog, and it
  stops on session change, backgrounding or draft import.
- `ContentSendStatus` (pure, unit tested) drives the status line. "Shown on
  reader" requires the redraw receipt for the exact revision on the canvas;
  storage-only activation, unknown outcomes and failures stay distinct.
  Identical cards already shown cannot be resent (it would only refresh e-ink).
- An empty draft cannot be sent from the studio, so clearing the reader is
  never a side effect of deleting cards.
- Drafts save locally one second after typing pauses; saving never contacts a
  reader. Load/save conflicts keep the explicit preserve-and-recover path, and
  draft import keeps its side-by-side review because it replaces every card.
- Demo shows one in-memory sample card; nothing is saved or sent.
- **Load cards from the reader…** (2026-09-25; sibling docs/content-read-v1.md)
  appears for identified readers that advertise `contentRead: 1`. It reads
  the active revision's manifest, cards and images in the reader lane,
  verifies the manifest against the revision and every file against the
  manifest (`ReaderContentPull`), and opens the result in the same review as
  a draft import ("Cards on X3"). Replace changes only the editor; nothing on
  the reader changes, and a failed or partial read leaves the draft as is.
- Removing a card is autosaved, so it is always undoable (2026-09-25): an
  inline Undo and ⌘Z put the card and the image only it used back at its old
  position, keeping later edits; restoring is refused (with a message) once
  the three-card limit is reached or the ID is in use.
- Preview inputs come from the reader (2026-09-25): `ReaderDisplayState` reads
  `GET /api/pocket/v1/display` once per connection and after a UI pack
  apply/revert, inside the sequential reader lane, and the canvas renders with
  its theme spacing, language, button labels and orientation. Without it
  (demo, offline, older firmware) the canvas uses a labelled default-theme
  reference (Lyra 20/5/16). A caption under the canvas names the source.
  `MacTests/PocketParityTests.swift` compares a host render with a captured
  reader frame (hardware run only; see sibling docs/pocket-profile-v1.md).
- Other "Apply" labels were renamed for what they send: reading settings use
  **Save settings**, the theme inspector uses **Send theme**.

## Home & Sleep profile editor (P2, 2026-09-25)

Home & Sleep is the first studio tab on every platform and edits the reader's
Pocket Daily profile (sibling docs/pocket-profile-v1.md). Since 2026-09-26 it
is organized around the two screens: a Home | Sleep switch above the canvas
picks the screen, and the controls show only that screen's modules. Home is
listed top to bottom as two blocks, Pages and Weather: dragging Weather above
or below Pages sets `home.weather` (top/bottom), its switch sets `off`, and
the next-event line and city/calendar settings open inside it (under the
Weather or Today row on Sleep). Pages and sleep sections are switched on and
dragged into order (`ModuleList`, with Move Up/Down in the context menu and
for assistive technologies). My cards open under their Home page and show the
selected card page on the canvas. Reader-wide settings (text size, side
buttons, front buttons following rotation) sit folded underneath both.

- On connection, when `/api/status` reports `pocketProfile: 1`, the app reads
  `GET /api/pocket/v1/profile` once inside the sequential connection lane.
  Readers without it show "cannot store Home & Sleep settings yet".
- `PocketProfile` mirrors the firmware rules (1-4 distinct Home items, 1-4
  distinct sleep sections) and sends exactly `schema`, `home` and `sleep`.
  `ReaderProfileState` refuses unknown IDs from a newer reader instead of
  dropping them, so the app never writes back a document that loses choices.
- The editor keeps a draft against the loaded profile; reloads never discard
  unsent edits. Apply posts the whole document once with the loaded
  generation (compare-and-swap). A 409 reloads the reader's version and asks
  for review; nothing is retried automatically.
- The canvas shows the Home or Daily Brief frame drawn by the firmware's own
  painter through the host renderer (`renderHome`/`renderBrief`, P1-3) with
  built-in sample content, captioned as sample data. The reader's real
  content, header theme and book cover differ; pixel agreement with a device
  capture is not yet measured. When the renderer or font is unavailable, or
  the sleep mode is the reader's own sleep screen, the labelled layout
  schematic is shown instead.
- The reader redraws Home and Sleep from a saved profile when Pocket Daily
  next paints, which is when Sync ends; the status line says so. Cards changed
  in the same Apply are shown at once through content presentation, and
  preferences take effect immediately. When `/api/status` reports
  `screenPresentation: 1` (sibling docs/pocket-screen-present-v1.md), Apply
  asks the reader to draw the screen being edited (Home, or the Daily Brief)
  after a layout change and follows the receipt with reads only
  (`ScreenPresenter`); cards changed in the same Apply are then not drawn
  separately. Demo edits locally and sends nothing.

## Explicit live editing session (superseded)

The studio's Auto-send toggle replaced this confirmation-gated flow on every
platform in 2026-09-25; the coalescing rules below still describe Auto-send.

Start live apply was a separate confirmation for the currently identified reader
and connection generation. It applies the current valid draft, then coalesces
subsequent edits after an800ms quiet interval. Only the newest draft is retained
while the existing Apply runs; an invalid edit clears the queued valid draft.
An unchanged confirmed revision does not trigger another Apply. Success requires
both activation and the matching reader redraw receipt. Failure or uncertainty
turns live apply off without an automatic retry. Normal Apply remains available
when live apply is off.

The authorization is not persisted. Closing the editor, leaving the active app,
changing the reader session, starting draft import/recovery, or Stop live apply
cancels pending work and the owned Apply. Cancellation cannot undo activation
already performed; existing pending-activation recovery remains authoritative.
Save remains local-only. In the explicitly enabled session, content edits,
including attached-image changes, may deploy without another confirmation.
No new endpoint, transport, network association or firmware installation is used.
Readers without presentation receipts and demo mode cannot enable live apply.

## Image conversion service

ContentImageImport loads a selected file off the main actor within security-scoped
access. Compressed input is bounded to20MiB; ImageIO accepts a single image with
dimensions <=32768 and <=100 million source pixels. It requests an oriented
thumbnail <=512px, not a full-size decoded source. App-owned RGBA scratch is
at most1MiB; this is not a bound on ImageIO codec internals. Transparency is
composited onto white, then weighted RGB luminance below128 becomes a black PBM
pixel. Output is canonical MSB-first P4 with zero unused row bits. Canonical PBM
input remains byte-exact. There is no dithering/threshold adjustment UI yet.

Image names use48 hex SHA-256 digits of the output bytes and fit the firmware
path limit. Editor attachment checks actual decoded dimensions and filename
collisions, preserves still-referenced shared images, and removes unreferenced
images from the draft only. Image import never saves; the explicit live session
may deploy the resulting edit. Cancellation
or changes to the selected card while decoding prevent attachment. Original
files are never modified. Choose/Replace image uses the shared native document
picker and binds the result to a stable card ID. Remove image prunes only assets
no longer referenced by any card. Preview decodes the canonical stored PBM off
the main actor into at most256KiB of grayscale pixels, preserving row order and
black/white polarity. These attachment thumbnails are separate from the offline
reader preview. Closing the editor cancels pending attachment.

The offline reader preview uses the shared native content renderer with bundled
PocketSansWorld 12 px, Base layout and English controls. It displays the selected
card and its image for the chosen profile/orientation, with explicit reference
configuration labeling. Editing is debounced; cancelled or superseded results
cannot replace the latest edit. Invalid content clears the frame and reports
the error. This works in demo mode without saving or contacting a device.
It is not a capture or confirmation of the connected reader's display; see
`HOST_RENDERER.md` for font provenance and remaining parity requirements.

Navigation hints now show separate Prev and Next actions instead of repeating
Prev/Next twice (2026-09-23). The firmware applies the corresponding localized
labels through its existing button mapper. The app's reference pixel test uses
the real bundled font and verifies these defaults against a direct host render;
the accepted renderer artifact and binary protocol are unchanged.

Demo editing uses a separate in-memory editor and disables Save/Apply; it never
loads or overwrites the normal saved draft. Recovery is unavailable in demo.
Conflict comparison and automatic screen confirmation remain pending.
Unit tests use temporary local files; UI tests edit in demo only. They do not
validate physical device transfers or filesystem power-loss durability.
