# Content and firmware transfers

Implemented locally 2026-09-27; physical acceptance remains required.

## User flow

- **Content · SD card** owns books, articles, written EPUB/TXT and learning packs.
  Write text to read only creates a content file. Send content never sends `.bin`
  files, even if firmware was prepared in an earlier session. Articles publish
  under `/Articles`, learning packs under `/pocket-daily/learning`, other books
  in the SD root. No content operation flashes the reader.
- **Firmware** checks GitHub metadata once per launch and shows the latest version
  and publication date. Update is offered against the connected reader; its
  acknowledgement starts download and transfer. Cancel stops and cleans up.
  Local firmware import is not offered in store builds. Interrupted updates show Resume/Cancel,
  with a local-only recovery action only after cleanup fails. The image
  is validated before preparation. Transfer publishes `/update.bin` on SD; it
  does not install it. The reader still requires its own confirmation before
  writing internal flash. Cancelling an app download sends nothing to the reader.
- **Development builds only** (`#if DEBUG`, added 2026-10-03): the Firmware card
  adds **Send a local build…** while a reader is connected, and a chosen or
  dropped `.bin` takes the same route. The image is checked first, the
  acknowledgement names its file, version and size, and it then uses the same
  preparation, transfer, cancellation and on-reader confirmation as an official
  update. The chosen file is copied, never moved or removed. It needs no
  download, so it is not limited to Same Wi-Fi. The reader skips its prompt when
  the staged version equals the running one; the acknowledgement says so.
  Release builds compile none of this and still refuse a local `.bin`.
- After an image is sent over Same Wi-Fi the reader is expected to leave Sync:
  it restarts with Wi-Fi off to ask, install and restart again, and does not
  return to Sync by itself. While the sent version is recorded, the status poll
  runs every 3 s and two misses end the session with an on-reader notice instead
  of the usual 15 s × 5. The Firmware card keeps the sent version for the last
  reader until that reader reports its version again.
- Content **Pause** closes the upload and retains its local copy and possible reader
  staging prefix. Send in that category retries/resumes it explicitly.
- Content **Stop and remove** waits for the cancelled request to drain, then removes
  prepared copies in that category and their tracked hidden staging files.
  Published books and `/update.bin` are untouched. An acknowledgement lost
  during publication cannot be treated as proof that publication did not happen.
- **Remove** after interruption uses the same cleanup. Failures retain the
  remaining queue for retry; successful earlier removals stay removed. Cleanup
  requires a re-probed matching reader ID and the new capability. Offline/legacy
  readers have an explicit **Remove only local copies** alternative, with a
  warning that it cannot confirm reader cleanup. Original article/source files
  are independent of this temporary transfer queue.
- Firmware already installed is not an upload and cannot be cancelled in this
  UI. Firmware already saved on SD keeps the existing on-reader install/cancel
  confirmation. No app action interrupts flashing.

## Cross-repository contract: transferControl 1

`/api/status` optionally advertises `transferControl: 1`. Only capable readers
receive `POST /api/pocket/v1/transfer`, JSON <=512 bytes:

```json
{"action":"prepare","kind":"content","staging":"/Articles/.pocket-12345678-abcd-0123-4567-123456789abc.part"}
```

`action` is `prepare` or `discard`; `kind` is `content` or `firmware`.
Success is HTTP 200 with `{"ok":true}`. The app validates that receipt.
Busy writers return 409, invalid input 400, failed SD removal 500.

Only a canonical lowercase UUID staging basename is allowed; normalized parent
paths must also pass the existing content write policy. Published paths and
`.pocket-backup.part` are never accepted. Discard is idempotent if the file is
already absent. It releases matching resume/commit state, but never deletes a
published target, clears firmware installation records, or performs a flash.

Prepare announces the kind before the existing port-82 stream; the verified
CRC/size commit protocol stays unchanged. Each queued item persists its exact
staging UUID before sending, including unidentified legacy readers. Cleanup is
not inferred safe for unidentified readers. Older identified queues derive the
same staging UUID from their existing item ID.

The existing reader Sync/File Transfer screen shows content vs firmware,
received percentage, waiting for publication, saved, interrupted, failed or
removed. Intermediate percentage repaints require a 5-point bucket change and
at least 2 seconds; phase transitions repaint immediately. The snapshot adds
bounded scalar state, no framebuffer, filename buffer or new heap allocation.
The existing stream and staged path storage are reused. Card/Home presentation
can replace this feedback when a new presentation is prepared.

## Acceptance

Local tests cover category separation, cleanup failure/retry, changed reader
identity, cancellation draining, legacy queue migration, staging name rejection,
and bounded percentage arithmetic. Builds/host tests are not hardware evidence.

On physical X3/X4, test both network modes: queue firmware plus written text;
send each separately; pause at several percentages; resume; stop/remove; drop
Wi-Fi during cleanup and retry; cancel a firmware download; lose a commit reply;
confirm existing books/update.bin survive cleanup; check all four orientations,
Unicode, e-ink update latency and heap while transferring. Verify SD contents
before and after. Installation remains a separate user-confirmed hardware step.

## Local verification record

- App full unit suite: 326 passed before the final cancellation/receipt additions.
  Subsequent focused coverage: 23 passed; after the final UI/copy changes the
  transfer separation/cleanup tests and the written-EPUB UI test passed.
  Final background-admission coverage also passed all eight transfer tests.
  The UI test checks separate Send content, cancellation of removal, persistence
  and confirmed removal. The queue screenshot was inspected.
- Firmware final: 441 host tests, 11 route tests; strict cppcheck no defects;
  default build no errors or warnings. Static build use: RAM 113,288 B,
  flash 6,008,801 B. These are not runtime heap or e-ink timing measurements.
- No application/device installation, flash, commit, push or release was performed.

- iOS/macOS final builds pass; all 11 Store screenshots regenerated and the
  source package validator passed. Representative iPhone/iPad/Mac images inspected.
  The first iPad full UI run timed out opening the share extension editor; its
  Xcode diagnostics collection stalled and was terminated. The same share test
  passed on rerun without a code change, together with written-EPUB and capture
  tests. The initial intermittent extension launch failure remains recorded,
  not diagnosed as a fixed product defect.

## 2026-09-27 simplified firmware card

GitHub [`published_at`](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)
is a release publication date, not an inferred reader
installation date. Metadata is cached for the app model lifetime; reconnection
compares the cached release against the new reader. Failed startup checks do not
loop and offer an explicit retry. Demo skips network checks. Download is always
explicit, and reader confirmation before flashing is unchanged. This changes no
reader endpoint contract. Legacy prepared firmware remains cancellable/resumable.

Simplification checks: 23 firmware/transfer unit tests pass, including cancellation
while preparing and while a reader request is pending. iPhone UI suite passes;
iPad has one initial share-extension activation timeout (12 other tests pass),
then the unchanged share test and screenshot capture pass on targeted retry.
This does not establish that the intermittent extension issue is fixed. The card
render fixture uses a synthetic release/date and does not represent a published
firmware release. Logs: `.build/firmware-simple-tests-final.log`,
`.build/firmware-simple-screenshots{,-retry}.log`.

Final macOS build/render tests and 3 store captures pass; all 11 store images
were regenerated. `validate_app_store.sh` and `git diff --check` pass. No new
SpringBoard crash report appeared during this sequential simulator run.

## Publication confirmation and compatibility — 2026-09-29

General file sends require an existing Pocket advertisement before any upload:
`transferControl:1`, a valid `uploadStreamPort`, or positive `uploadChunkBytes`.
These are compatibility evidence from the existing Pocket protocol; a generic
CrossPoint `/api/status` plus browser `/upload` is insufficient. No new firmware
capability or route is assumed. Unrecognized firmware is rejected before staging;
use supported Pocket firmware or the Mac SD-copy path.

Each prepared item can now carry optional `publicationPending:true`. Old queues
without the field remain readable. The app writes this marker atomically before
sending commit, off the main thread. Successful verified publication removes the
queue item. A lost/malformed reply, cancellation, app exit, or local cleanup failure
can leave the marker. Resume refuses to upload that item again. Check the reader,
then explicitly remove the prepared copy before preparing a replacement. Removing
prepared copies still never removes a published target. This is intentionally
conservative even when commit was rejected or cancellation preceded the request.
It is not a receipt or proof that the reader published the file.

A future firmware receipt/idempotent-commit contract can resolve these records
without manual inspection. Until that exists, the app must preserve uncertainty;
it cannot promise that the previous target survived every client-side error.
