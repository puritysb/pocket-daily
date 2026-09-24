# Local theme draft

The eight-metric theme inspector edits a `ThemeDraft` independently of a reader.
`Save theme draft` explicitly persists it; Apply/Revert remain separate device
actions. Saving never connects, uploads, activates a pack or flashes firmware.
Applying takes the current value snapshot, including unsaved edits, and uses
the existing PDUI encoder and verified activation path without changing its
wire format. Values are local defaults/edits, not a readback of the active pack.

`PocketModel`, shared by the app's windows, owns one normal editor/store and a
separate demo editor. The demo editor has no storage dependency; its save method
refuses persistence even if called outside the UI. Switching modes does not mix
their drafts. Normal unsaved edits survive view recreation in the same app
session; only an explicit Save survives a later process launch.

## Storage and concurrency

`ThemeDraftStore` is an actor. It reads/writes Application Support /
`Pocket/Studio/theme-draft.json` off the main actor. A schema1 record contains
`schema`, positive UInt64 `generation`, and the typed `draft`. Schema2 adds a
required UUID `recoveryID` after an explicit recovery; subsequent saves preserve
that epoch and schema. Schema1 must not carry a recovery ID. Readers which only
understand schema1 refuse recovered records rather than ignoring the epoch.
Reads are bounded
to16KiB plus one overflow-detection byte. Unknown schema, malformed data, zero
generation and invalid metrics fail rather than becoming an empty draft.
Schema must change when the persisted document's meaning changes.

Every save validates the draft, rereads the current record and compares the
caller's generation and recovery ID before atomically replacing it. A stale editor fails without
overwriting newer data; an unchanged save does not rewrite or increment the
record. Generation exhaustion is rejected. These are same-actor guarantees,
not cross-process locking or filesystem power-loss durability claims.

The authoring limits match the existing controls: header20–120, list/menu
rows30–120, menu spacing0–32, tab bar20–80, side padding0–64 and popup radius0–32;
popup bold is a Boolean. This is not the full PDUI registry or a claim that all
possible theme compositions are physically validated. The eight fields still
encode as the same existing typed metric records.

`ThemeEditorModel` rejects overlapping operations and save-before-load. Loading
cannot replace edits made while I/O was suspended, including edit-away-and-back
sequences. Saving captures an immutable snapshot and records its generation
without replacing newer typing. A completed write's receipt is retained even
if the caller cancelled during I/O. Storage failures leave the in-memory draft.

## Explicit recovery

Failed initial loads expose Retry and disable editing/saving until the saved
data is readable; there is no implicit replacement. After a load/save error,
the user may separately confirm recovery. It validates current in-memory values,
copies the original regular file byte-for-byte to a unique
`theme-draft-backup-<UUID>.json` sibling, then atomically publishes the chosen
draft as schema2/generation1 with a new recovery ID. A failed initial load leaves
the editor defaults as the chosen values, which the confirmation explains.
Unknown-schema, corrupt and oversized files are copied without decoding or
truncating the backup. Directory/symlink targets and failed copies stop recovery.
Publication failures retain the completed backup and expose its location.

The editor keeps later typing separate from the recovered snapshot, retains the
new epoch, and permits ordinary saves again. Demo recovery is refused by the
model as well as hidden in the UI. The latest backup has an explicit export
action; no backups are automatically deleted. Backup comparison and browsing
remain unfinished. Portable editing files are a separate format described below.

Multiple named packs, resource/font documents and UI-pack host rendering are
also unfinished. The content preview uses its own explicit Base reference
configuration; it does not preview these theme edits.
Reader Revert retains its separate capability/identity/session gate, so an
unreadable local draft does not block reverting a supported connected reader.

Tests cover reopen/byte-exact PDUI encoding, stale saves, every metric boundary,
corrupt/unknown/oversized records, generation exhaustion, demo isolation and
typing during load/save, recovery byte preservation, epoch conflicts and
non-regular target refusal. Controlled suspended recovery also checks overlapping
operation refusal, preservation of newer edits and retention of a completed
write's epoch after caller cancellation. They use temporary local files, not a reader.

The recovery UI test uses `POCKET_UI_TEST_THEME_DRAFT_ID` with a fresh UUID in
a DEBUG build. Its actor creates a corrupt fixture under the app's temporary
`PocketThemeUITests/<UUID>/` directory, never the normal Application Support
draft, and preserves that fixture across the test's relaunch. The environment
hook and fixture store do not compile into Release builds. The test cancels the
alert, confirms recovery, checks the preserved-file export action, saves an edit
and relaunches to verify it. It does not invoke device actions or share a file.

## Portable theme files

`Export theme draft…` creates an immutable snapshot of the current eight metrics,
including unsaved edits, through the native JSON file exporter. It does not save
the app's private draft, activate a pack, or export fonts/resources/firmware.
The suggested filename is `Pocket Theme.pocket-theme.json`. The JSON envelope
contains exactly `format: "pocket-daily/theme-draft"`, `schema: 1`, and `draft`.
The eight draft keys match the editor model. No reader identity, local generation,
recovery epoch, paths, credentials or activation receipt is included.

`Import theme draft…` uses the existing native document picker, then bounded
off-main-thread reads with security-scoped access. At most16KiB plus one overflow
detection byte is read. Empty/oversized/malformed documents, wrong format/version,
unknown/missing fields, incorrect value types and out-of-range metrics are
refused. Private saved records and `.uipack` binaries are not this format and
cannot be imported as theme JSON. A future meaning change requires a schema bump;
unknown fields are refused instead of silently discarded on re-export.

A valid file opens a current/imported comparison for all eight metrics. Cancel
leaves the draft unchanged; Replace draft updates memory only. Save and Apply
remain separate explicit actions. The app must have loaded its saved draft
before import/export, and demo refuses both in the model and UI. Import errors
are separate from local-store errors and do not offer irrelevant recovery.

The shared model serializes file reads with local load/save/recovery operations.
An edit generation and proposal UUID reject late reads or stale confirmations,
including edit-away-and-back and another window reloading the draft. Export
captures a value snapshot so later typing cannot change the selected document.
Cancelled reads never stage a proposal. This does not add cross-process locking.

Unit tests cover byte-equivalent PDUI round trips, schema/field/boundary failures,
bounded source-preserving file reads, explicit confirmation/save, immutable export
snapshots, demo isolation and import cancellation/edit races. The UI regression
uses the DEBUG-only `POCKET_UI_TEST_THEME_IMPORT_ID` UUID fixture hook to bypass
the simulator's Files provider selection, then exercises the real JSON file
reader and review UI. It cancels, confirms without saving/relaunches, and finally
confirms/saves/relaunches. The native provider picker and actual export destination
selection are not verified by that fixture test. Release excludes the hook.
