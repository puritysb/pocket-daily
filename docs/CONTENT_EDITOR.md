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

The studio now opens ContentEditorSheet from “Edit content cards…”. Shared local
editor state survives closing the sheet during the app session; Save draft
persists it across launches. Text cards can be added, edited, reordered and
removed. UTF-8 byte counts and publish validation are shown without truncating
input. Apply requires explicit confirmation (including the empty-set meaning)
and calls PocketModel's exclusive deployment lane; it never saves implicitly.
Deployment labels distinguish stored activation from actual screen confirmation.

## Explicit live editing session

Start live apply is a separate confirmation for the currently identified reader
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
