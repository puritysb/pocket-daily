# Content deployment coordinator

Seal inventory follow-up (2026-09-22): the sibling now refuses a revision unless
its flat directory contains exactly the verified manifest and assets, with exact
logical byte totals and a bounded raw-directory scan. Extra/temporary files,
child directories, unreadable/unsupported entries or exhausted scan work refuse
seal without activating. Already-published retries and post-move readback receive
the same gate. Existing response schemas/HTTP422 failures are unchanged; the
Swift adapter still stages only the manifest and declared assets, and never
automatically repeats activation or deletes reader leftovers. This is not
pre-upload capacity admission, aggregate quota or physical SD verification.

An ambiguous activation retains the target revision, required capabilities
and pre-activation generation. “Check activation
outcome” performs exactly one state read on the currently selected address of
the original reader, under the existing exclusive session lane. It requires
matching identity/revision and a strictly newer generation, and never stages,
uploads or repeats activation. Failure/cancellation retains the unknown outcome
for another read. A completed confirmation clears the pending receipt. The
pending operation survives app restart via ContentActivationJournal; this
confirms storage only, not a physical-screen repaint. Device identity is not
cryptographic authentication.

The app atomically writes a bounded schema1 intent (UUID, reader ID, revision,
capabilities and prior generation) to Application Support/Pocket/Studio/
content-activation.json before sending activation. Failed persistence prevents
activation. Any crash after intent publication conservatively leaves an unknown
outcome, even if no command was sent. A matching confirmed state clears the exact
intent using an atomic empty record; failed cleanup retains the pending state.
Opening the editor restores it locally without connecting. Apply checks for an
unresolved record before any staging, and never overwrites it. Malformed,
oversized or unsupported records fail closed. The store is one app-owned actor,
not a cross-process lock or a power-loss durability guarantee.

“Archive pending check…” is an explicit, separately confirmed local action for
an unreachable reader or permanently unconfirmable intent. It copies the exact
current record to a unique sibling archive before clearing the matching pending
record. A mismatch or persistence error retains the unknown state. This never
issues an activation/upload command, cancels/undoes activation, or starts another
deployment. Existing background monitoring can resume after the local operation.
The UI retains an unknown-outcome label and exposes export of the archive; a
subsequent Apply is a separate user action. Demo cannot archive. Archives are
not automatically deleted. Persistent archive browsing remains pending.

If activation tracking cannot be decoded, the editor offers a separate confirmed
recovery action. The store rechecks that the current file actually fails parsing,
size/schema or field validation; valid/absent records and I/O failures are refused.
Only a regular file can be recovered, never a directory or symlink. Exact bytes
are copied to a unique recovery backup before an atomic empty tracking record is
published. Failure leaves the error visible; successful recovery exposes backup
export without applying content. Normal background monitoring may resume, but
no deployment command is issued by recovery. Demo cannot recover. This retains
the same shared-actor, not cross-process, concurrency boundary.

Preparation can now reuse unchanged files from the firmware's recovered active
revision. The reader copies matching path/size/SHA files into staging and
rechecks the copy before setting a verified bit. The app skips only those
verified candidate bytes; presence in an old revision alone is insufficient.
The schema1 receipt is unchanged. Older readers can still require every file;
actual copy/create/readback failures now stop preparation with HTTP503 instead
of triggering fallback uploads. Absent/nonmatching source files still use normal
uploads. This avoids resending
an unchanged image for a text-only edit, without changing firmware or activation
semantics. Local contract tests are not physical-network performance evidence.

`Sources/Studio/ContentDeployment.swift` implements the app-side execution order
against an internal `ContentDeploymentTransport` interface, now implemented by
`ReaderContentTransport` using the existing client. The text-card editor now
binds Apply to PocketModel, but **the complete capability is not yet advertised**.
Firmware now loads verified cards on Pocket activity entry and draws PBM images
in the detail view's remaining space. The optional live presentation path below
is implemented locally; physical rendering acceptance remains incomplete. This is
not evidence of a released or physically validated workflow.

Local authoring state and persistence are implemented by ContentEditorModel and
ContentDraftStore; see [CONTENT_EDITOR.md](CONTENT_EDITOR.md). Draft save does
not trigger deployment. The editor's explicit Apply action requires confirmation.

`PocketModel.applyContent` now owns the app-level execution path: it rejects
demo/background/disconnected/unidentified/unsupported readers and concurrent
operations, captures the selected reader/host/session generation, and runs the
coordinator in the existing transfer task. It quiesces frame/preferences/heartbeat
traffic first and uses existing background/session cancellation. On completion
it restores paced reader traffic only for the same active session. Activation
uncertainty is shown separately from cancellation before activation. Storage
selection and a reader-reported completed redraw have separate outcomes. No firmware upload,
network switch or automatic invocation on draft save is introduced.

App admission tests cover non-mutating refusal paths. A URLProtocol test also
drives the real PocketModel through reader selection and an already-active
content response, checking exclusive task ownership, release and absence of
staging/upload/activation requests. Coordinator/adapter tests
cover execution separately with injected I/O; full app-to-device lifecycle
acceptance remains unverified. The text editor now provides the UI controls.

## Execution and evidence

1. Read state from the expected reader. Require schema1 and capability bit1 for
   cards, plus bit2 for images (same masks as firmware `ContentManifest.h`).
   Reject invalid active revision/generation records. If the target is already
   verified active, finish without preparing, uploading or activating.
2. Prepare the target manifest in its revision-specific staging directory.
   Check the reader identity and revision returned by preparation.
3. Skip a file only when preparation reports that exact path/kind/size/SHA-256
   verified in **this candidate directory**. Local previous-edit history is not
   a receipt. Unknown/duplicate inventory entries are rejected; changed files
   are sent serially, checking each destination receipt.
4. Ask for sealing/activation once. Whether the call returns or throws, query
   state to establish the outcome; do not retry the mutation automatically.
5. Success requires the same reader, exact target revision, positive generation,
   and a generation newer than the prior active selection when replacing one.
   It proves verified stored selection, not that pixels have been rendered.

Concurrent deploy calls on the same coordinator fail with `busy` without
changing the in-flight phase. Once an outcome is unresolved, repeated Apply
(including a different edited revision) is refused before any transport call or
state reset. The original pending snapshot remains available to read-only
confirmation, even without a disk journal. Cancellation/failure before activation
never sends activation; after activation begins it leaves `needsConfirmation`.
Only a resolved or explicitly archived operation permits a new deployment,
which reads device state first. No timers or background retry loop exist.

## Reader adapter and firmware contract

`ReaderContentTransport` binds one immutable revision, expected reader ID and
host/port. It stages `manifest.pdcm`, inspects the candidate, stages missing
assets serially and verifies each uploaded asset through the preparation
receipt before allowing activation. It rejects other manifests/assets/revisions
and unexpected publication paths. Existing verified candidate assets are skipped;
unchanged active assets can be copied and verified by reader preparation.

The production adapter uses `CrossPointClient.uploadAtomically`, obtaining fresh
stream capabilities from `/api/status` and checking identity before each file.
It requires an advertised valid stream port because that server creates nested
staging directories. Temporary local files are written off the main actor and
removed after transfer. It neither discovers readers nor changes networks.
Existing bounded stream retry/recovery remains; no reconnect callback is supplied.
Identity checks are consistency checks, not authentication or a race-free
identity binding of the legacy stream/commit protocol.

Firmware registers `GET /api/pocket/v1/content/state?deviceID=<8hex>` and
`POST /api/pocket/v1/content/activate?deviceID=<8hex>&revision=<64lowerhex>`.
Both return schema1, deviceID, capabilities (cards1/images2), and `active`,
explicitly null or `{revision,generation}`. Missing/invalid active fields are
errors in Swift. State uses full stored-revision recovery; activation seals and
verifies the candidate before updating redundant active records. HTTP409 rejects
live writers/wrong identity;503 signals unavailable/unverified state or ambiguous
activation outcome;422 rejects a candidate that cannot be sealed. The coordinator
reads state after activation even if its response is lost. These responses prove
storage selection, not screen rendering, and do not flash or reboot firmware.

After successful activation, newer firmware attempts bounded retirement of the
single revision evicted from its two recovery records. Both recorded revisions
and any displayed/queued/failed presentation remain protected. Only validated
manifest-listed files are candidates; unknown files are never recursively
deleted. Cleanup failure does not change the successful activation response or
trigger an app retry. The schema1 receipt and Swift interpretation are unchanged.
This is not total-storage quota enforcement: abandoned staging, interrupted
cleanup and older orphaned revisions still require follow-up work. See sibling
`docs/content-retention.md`; host tests are not physical SD/power-cut evidence.

Newer firmware also caps individual staging uploads at256KiB, including resumed
prefixes, temporary files and legacy transfer/move paths. Swift's existing
manifest/asset bounds fit this ceiling; receipt schemas are unchanged. This is
only an ingress bound, not a free-space receipt, total staging quota or a reason
to retry failed transfers automatically. A full SD card can still fail writes.
See sibling `docs/content-storage-admission.md` for enforcement and remaining work.

The firmware now implements a read-only `POST /api/pocket/v1/content/prepare`
inspection endpoint after manifest staging, paired with Swift
`ContentPreparationReceipt`. `CrossPointClient.inspectPreparedContent` now calls
that endpoint through the existing per-reader HTTP queue with an uppercase
eight-hex device ID, revision query, no-cache policy and15-second timeout. It
does not stage the manifest or retry409/503 responses. Responses above512 bytes
are rejected before receipt decoding. URLProtocol tests exercise the actual
client request/response path without contacting a reader.
See sibling `docs/content-prepare-v1.md` for query
and response fields. Its bounded bitmask maps to canonical manifest entry order.
Preparation can copy unchanged active assets under the verification rules above.

## Live presentation without ending the selected session

Firmware seal retries now reclaim a fully verified duplicate staging tree when
the same revision is already valid in the published tree. The published copy
requires full verification; staging requires the same verified manifest and an
exact inventory of verified remaining assets. A later explicit seal can resume
partial deletion without recreating removed assets. Unknown/corrupt staging or
a missing manifest is preserved. Cleanup failure does not change the successful published receipt
or authorize an app resend. No HTTP schema or Swift staging/activation sequence
changes. This fixes one accumulation path, not free-space reservation, total
quota or durable abandoned-transfer cleanup. The32 deployment/adapter/HTTP
tests remain the cross-repository compatibility check; physical SD behavior is
not implied.

### App transfer ownership

Files, content Apply, pending-activation checks, theme Apply/Revert, settings
saves, explicit preview fetches, offline file preparation, SD copying, local
activation-journal recovery/archive, LAN discovery, manual verification, explicit
private association and explicit session end share
`PocketModel.startReaderWork`/`finishReaderWork`. Each operation has a UUID in
addition to the selected connection generation. Optional reader traffic drains
before network/session work starts; local-only work does not stop or restart
reader monitoring. Only the owning operation releases the task/busy state.
Cancellation keeps the lane occupied until I/O returns, including an I/O
implementation that ignores cancellation. Discovery and manual verification
cannot replace the connection while that lane remains occupied. Late upload
notes, progress and private-link recovery check both operation and session
ownership before touching state or requesting an association.
The work kind distinguishes transfer/settings/preview/local/session/discovery/connection; only
transfers expose file-transfer controls. All kinds retain their busy/task ownership
through cancellation drain. There is no separate settings/preview task handle
or background path that clears it while its I/O is still running. Connection
verification, discovery, direct-lease replacement and session-end admission
respect this same owner.

Local file work reserves admission synchronously, before starting file-provider
I/O. Demo/background requests cannot start preparation or SD writes. A completed
non-interruptible local write keeps its receipt even if background cancellation
arrives while waiting; the next operation waits for the prior I/O to drain.
LAN discovery now also uses this lane: reservation is synchronous, both bounded
scan passes and their retry delay have one owner, and Bonjour is cancelled and
awaited before release. Duplicate discovery, manual verification, local file work
and session end cannot replace a still-draining search. Background cancellation
does not release a non-cooperative discovery provider early. Search ranges,
timeouts and the one-retry policy are unchanged.

Manual verification and private association no longer own separate task handles
or busy-state cleanup. An explicit connection request may replace another
connection request, but not a transfer, discovery or local operation. Replacement
reserves the next owner immediately, cancels the predecessor and waits for its
I/O and cleanup before starting. A superseded queued request never performs I/O;
only the latest still-owned request proceeds. Cancelled OS association success
is cleaned up before a replacement, including a same-SSID replacement. Background
cancellation retains ownership until that cleanup returns. Foreground alone does
not join or verify. Entry points that previously scheduled untracked verification
tasks now reserve synchronously. Network selection, endpoint contracts and user
authorization for direct connection are unchanged.

This consolidates app operation ownership, not the entire planned DeviceSession
split, view migration, physical OS-association behavior or long-idle acceptance.

### Same-content Apply after a redraw failure

The existing deployment coordinator reads verified active storage before staging.
If the requested revision is already active, it returns that generation without
uploading even the manifest or activating again. PocketModel then requests the
redraw on the same selected session. A lost presentation POST response is resolved
by bounded read-only presentation queries, never by repeating the POST internally.
A failed/stale/unavailable display result leaves storage activation complete and
screen confirmation absent. Another explicit Apply can retry presentation through
the same read-before-staging path. This is implemented behavior, not a reason to
add another retry transport or require firmware installation.

The regression `testVerificationCannotReplaceTransferWhileCancellationDrains`
failed before the fix: manual verification issued HTTP while a cancelled Apply
still owned I/O, cleared busy state and replaced the reader status. It now
covers explicit cancellation and background/foreground, no verification HTTP
or rediscovery during drain, and a subsequent successful Apply. I/O is injected;
the test never joins Wi-Fi or contacts a physical reader. Settings/preview
tests additionally hold actual URLSession requests through a URLProtocol seam,
refuse replacement verification and discovery, preserve the distinction from
transfer UI, and verify background cancellation releases the lane only after
the request stops. Local-file admission tests hold preparation/copy I/O through
background cancellation and verify completed receipts survive, while duplicate
file work and connection replacement are refused. Firmware activity lifetimes,
the entire planned DeviceSession migration are not covered by this app-work
unification. The discovery test
holds a non-cooperative Bonjour provider through background/foreground, rejects
replacement operations without HTTP, drains it, then starts a fresh search.
Connection tests hold both OS association and cleanup, replace requests with the
same/different SSID, and verify that intermediate queued requests never join.
Actual URLSession verification cancellation/replacement is exercised with a local
URLProtocol; these are not real wireless-association tests.

When status advertises `contentPresentation: true`, Apply follows confirmed
storage activation with one `POST /api/pocket/v1/content/present`, then at most
eight `GET /api/pocket/v1/content/presentation` polls, spaced by 500 ms. Both
use `deviceID` and `revision` query parameters. A lost POST response permits a
read-only recovery lookup, never a repeated POST. Each HTTP request retains its
15-second timeout; the poll count is bounded, not a four-second overall deadline.

The schema1 receipt carries `deviceID`, `revision`, positive `generation` and
`phase` (`queued`, `rendered`, or `failed`). All identity/revision/generation
fields must match the confirmed activation. `rendered` means the firmware's
display-driver call returned, not optical verification of physical pixels.
PocketModel retains this exact receipt separately from storage activation, so
the editor can report the completed redraw instead of always saying screen
unconfirmed. Starting another Apply clears the previous redraw receipt; a
failed new transfer cannot inherit the old revision's display confirmation.

The firmware hosts the content view within File Transfer, retaining its server
and Wi-Fi session. No session-end, reboot, network switch or firmware update is
part of presentation. Failure leaves the app's confirmed storage activation
intact and reports the redraw as unconfirmed without resending content. Older
readers retain storage-only reporting. Explicit activation-outcome recovery
remains read-only and does not automatically request presentation.

Local tests cover receipt validation, lost-response recovery, cancellation,
bounded polling and actual PocketModel success/failure paths with mocked HTTP.
The same-model integration runs two revisions with an intervening upload
failure, asserting session selection, previous activation preservation, verified
image reuse, cleared durable intents and matching redraw receipts. Its injected
storage inventory represents firmware-verified candidate reuse; it does not
execute the real SD copy or upload socket. Unexpected HTTP paths are rejected
by the test instead of reaching any network.
They do not establish hardware heap safety, physical repaint or LAN reliability.

- Bind every mutation to the expected reader identity. Identity comparison is
  a routing consistency check, not cryptographic LAN authentication.
- Prepare must store the canonical manifest under
  `/pocket-daily/content-staging/<revision>` and report only files actually
  verified there. Copying unchanged files from a prior revision is firmware
  work; this coordinator does not assume that copy already occurred.
- Upload must publish the requested asset atomically and never target the
  protected `/pocket-daily/content` tree directly.
- Activation must own staging exclusively, call the firmware's sealing and
  activation stores, and preserve prior content on failure.
- State must use fully verified recovery, not metadata CRC alone. Unreadable or
  unverified storage must throw, not become an apparently empty active state.
- Product authorization, device rendering and complete session ownership still
  need implementation and verification before enabling the shipping UI.

Tests use an in-memory transport to cover sequencing, verified-file skipping,
idempotency, lost activation reply, unconfirmed outcomes, identity/capability
mismatches, duplicate inventory, cancellation, generation ordering and overlap.
ReaderContentTransport tests also drive the real coordinator through the adapter
with injected I/O: manifest/asset sequencing, candidate reuse, corrupt upload
rejection, immutable input/identity checks and lost activation responses.
An authoring-flow test saves and reloads an actual local draft, captures an
immutable revision while later edits remain unsaved, activates through the real
coordinator/adapter with injected reader I/O, and exercises a lost presentation
response followed by a failed redraw receipt. Storage remains confirmed and no
content or activation is repeated; reapplying the confirmed snapshot also skips
uploads. This is local integration coverage, not a physical reader acceptance test.
URLProtocol tests separately exercise the real content HTTP client. These tests
do not exercise physical stream sockets, SD writes or actual display behavior.
