# Transfer reliability changes — 2026-09-21

## Local test timing follow-up — 2026-09-22

The233-test run in `.build/content-pending-reentry-regression.log` had one
localhost six-MiB flow-control failure (`stalled`,1887.852 seconds). Read-only
`pmset -g log` inspection established that this run overlapped host sleep:
at18:29:34 the Mac entered sleep for944 seconds, woke briefly at18:45:18,
then slept again at18:45:20 for908 seconds until19:00:28. The test ran from
18:29:00 to19:00:27.99. This is a sleep-interrupted test run, not evidence of
reader radio failure. The unchanged isolated test subsequently passed in129.316
seconds (`.build/content-flow-isolated.log`). A passing rerun does not prove
absence of every possible transport race.

The test now retains only its last confirmed offset/time and reports these on
failure alongside total elapsed time. It keeps the same payload, assertions,
timeouts and single attempt. No production retry, pacing or timeout was changed.
When a local timing test fails, correlate its timestamps with host execution
and sleep before treating it as a device defect. Do not silently mark a failed
run green, shrink its payload, change host power settings, or use it to justify
another reader upload. No physical reader was contacted in these tests.
The subsequent full233-test run, including these diagnostics, passes in172.461
seconds (`.build/content-flow-regression.log`). The earlier failure remains in
its original log; this result is a separate successful run.

## Historical implementation context

These are coordinated, uncommitted changes in the app and sibling firmware
repositories. The experimental image is now installed on the X3 through the
one-time SD bootstrap; broader hardware acceptance remains required. Do not
infer a general radio or heap fix from passing host tests.

## Structural changes

Core follow-up: sibling `docs/CORE_CONNECTIVITY_REPAIR.md` records the
separation of remote installation from heavy diagnostics (4496 B less static
RAM in the default developer build), and an opt-in `sta_recovery` driver-init
buffer-budget experiment. This does not change app protocols, Mac Wi-Fi or the
normal production driver settings. These changes are in the installed experimental image.
The next receive-path change bypasses Arduino's additional 1436-byte RX buffer
on port 82 and detects orderly peer EOF directly, with host socket-pair tests.
The old image's 1 KiB probe received RESUME 0 but never returned final OK; this
rules out treating only multi-megabyte delivery as the unverified hardware gate.

| Boundary | Behavior |
| --- | --- |
| Mode ownership | Pocket Sync → Join a Network uses COMPANION: app endpoints and UI packs without browser route tables, mDNS, UDP discovery or WebDAV. File Transfer retains its browser surface. |
| Transfer ownership | Upload/commit/apply paths cancel and drain tracked frame, preferences-refresh and heartbeat tasks. This is not yet a global request arbiter; see the scheduling audit below. Firmware services payload before HTTP and releases WS resources until socket cleanup plus a five-second quiet period. |
| Receiver backpressure | `uploadStreamWindow:4096` opts into `Window: 4096` and SD-accepted ACKs. One block can be outstanding. No extra firmware payload allocation. Legacy clients/readers retain the old protocol. |
| Recovery | Paced LAN probes, same-reader identity checks and bounded retries. Transport timeout replies are retryable; SD/checksum/identity errors are terminal. |
| Live connection | Successful heartbeat can restart a stopped WS client. Pending frames have an explicit spacing deadline and stale session results are ignored. |
| First-time packs | Missing staging directories are created. A truncated SD pack is rejected before accessing SHA fields. |

The firmware contract is `docs/live-studio-v1.md` in the sibling repository.
The app acceptance checklist is [CONNECTIVITY_VALIDATION.md](CONNECTIVITY_VALIDATION.md).

## Historical evidence: failed old-image bootstrap

The available X3 reported `1.6.6-audit` and 8,368 bytes free immediately after
connection; a later successful status response reported 6,356 bytes. Those are
observations of the old image, not measurements of the changed code.

A paced bootstrap attempt received `RESUME 0`, then timed out after the sender
had submitted 131,072 bytes. This counter measures client socket submissions,
not bytes safely stored on the reader. There was no final OK/CRC or commit, so
this was not a successful `/update.bin` publication. No flash command was sent.

The production-profile image used in the failed bootstrap attempts:

- Environment: `gh_release`, version `1.6.6`.
- Size: 6,028,448 bytes.
- SHA-256: `185930f6b3cd90e8ea83599d0ee2053c4a85160a11d891cee855640e5d13f1d7`.
- Archived sibling path: `firmware/pocket-daily-1.6.6-gh_release-b8e38e39-20260921-011903.bin`.
  Check `firmware/LATEST_BUILD.txt` before using `firmware/update.bin`, because
  subsequent developer builds replace that path.

Bootstrap over the old File Transfer STA path with `scripts/pocket_put.py`.
The tool supports bounded startup probing and `--legacy-delay-ms` pacing.
It now automatically resumes up to three attempts, verifies the same device ID
before retrying and treats SD/protocol/CRC failures as terminal. After the user
rejoined the network, the audit image again disconnected following 131,072
socket-submitted bytes; subsequent port-82 connections timed out even while
HTTP status remained responsive. This is not evidence of a Wi-Fi-wide outage.
On a later fresh File Transfer connection, status initially reported 8,628 B
free. An alternative 16 KiB HTTP multipart chunk timed out without any success
response; subsequent status/connect attempts also timed out. A 512-byte paced
stream attempt could not pass its status preflight, so its payload behavior
was not tested. No target publication or installation was verified. USB is
unavailable; a reader-created File Transfer hotspot is the next distinct
bootstrap path to try, bypassing the home router.
The user subsequently ruled out a hotspot because it would disconnect the
Mac's internet; keep the Mac on its existing network. A later STA attempt did
reach `RESUME 0` with 512-byte writes paced at 40 ms, but both bounded attempts
failed (timeout/broken pipe), with the second handshake again at offset zero.
The following 1 KiB probe failed during status preflight, before sending any
test payload. Smaller writes therefore did not establish a working bootstrap;
small-file SD behavior itself remains untested. No new firmware was installed.
If that running firmware cannot sustain delivery, a reader-side mode restart
or a one-time SD/USB installation is needed before the new transfer protocol
can be exercised. After installation, use Pocket Sync → Join a Network and
check `uploadStreamWindow:4096`, then test content/pack/firmware delivery.

## Remaining limits

### App scheduling audit — 2026-09-22

Read-only source inspection, not a device reproduction or a root-cause claim.
The installed `w998f2f9d` remains unchanged; no device requests were made for
this audit. The later pre-payload CLI failures cannot be attributed solely to
these app scheduling defects.

- `PocketModel.quiesceReaderTraffic()` cancels and awaits the tracked frame,
  preferences-refresh and heartbeat tasks. `sendPreparedFiles()` reserves
  `isWorking` synchronously before creating its task and calls this drain.
- `savePreferences()` does not check `isWorking` or reserve it until its task
  begins. Two calls in one main-actor turn can therefore schedule two writes.
  Either task's defer can clear the shared flag while the other is pending.
  It neither drains background reads nor captures a connection generation;
  its completion can mutate state after the selected reader changes.
- `loadReaderPreview()` reserves the flag synchronously and checks the
  generation after requests, but does not drain requests already in flight.
  Setting the flag prevents future background work, not existing I/O.
- Frame, preferences-refresh and heartbeat requests have independent task
  slots. Their entry guards do not serialize them against each other.
  `CrossPointClient` uses a shared URLSession by default, not an explicit
  reader-wide request scheduler.
- Existing heartbeat tests exercise the failure counter. They do not prove
  operation ownership, request ordering, or stale completion isolation.

Next app acceptance gate: controlled asynchronous client responses must show
that a user operation reserves ownership before yielding, background requests
finish/cancel before the write begins, repeated calls cannot double-write,
and a completion from an old connection cannot release or mutate the new
connection. This can be reproduced and fixed locally without a firmware
upload. A global ownership fix must cover preview/settings as well as upload;
merely reducing HTTP connection count does not establish session ownership.

Local correction following this audit: settings now reserves `isWorking`
before task creation, rejects busy/disconnected calls, captures the endpoint
and connection generation, and ignores stale completions. Settings and manual
preview both use the existing background-task drain and resume paced heartbeat
after completion. Backgrounding cancels their tracked operation. A newer local
preference edit stays dirty when an older save completes. Injected URLSession
tests exercise the actual model for same-turn duplicate save/preview rejection
and cancellation before network start, including stale ownership release.
Follow-up controlled in-flight tests now hold actual URLSession responses:
background cancellation reaches both pending settings and preview requests,
their old completion cannot release a newly reserved settings operation, and
the shipping 15-second heartbeat request is stopped before the settings POST
starts (zero older active requests at POST entry). All five ownership tests
pass in `.build/inflight-ownership-tests.log`. These tests use a local
URLProtocol substitute, not a physical reader. At that checkpoint independent
idle background reads were still possible; the HTTP follow-up below addresses
that overlap. Frame/preferences-refresh drain coverage and a global operation
arbiter remain open. No firmware protocol or installed image change is required.

HTTP scheduling follow-up: the shared `CrossPointClient` now routes all its
URLSession data requests through a cancellation-aware per-host FIFO. An actor
alone did not serialize I/O across suspension points. Status, paged frames,
preferences, diagnostics, apply and commit now share the same HTTP admission
boundary; different hosts remain concurrent for discovery. Cancelling a
queued request removes it without sending it, and success/failure/cancellation
of the active request releases the next waiter. Host names are compared
case-insensitively; distinct DNS aliases of the same device are not unified.

This is per-request HTTP serialization, not a substitute for model-level
operation ownership. The separate bulk stream/multipart uploader and WS still
use the existing transfer quiescence rules. Frame paging can interleave with
other HTTP requests between pages; no immutable frame snapshot is claimed.
No endpoint, firmware contract, polling frequency or network mode was changed.
All 99 app unit/integration tests pass, including the three new HTTP admission
tests and 6 MiB transfer regressions; iOS and macOS builds pass. Evidence:
`.build/http-serialization-tests.log`, `.build/http-serialization-ios.log`,
`.build/http-serialization-mac.log`. Physical device behavior remains unverified.

Discovery retry ownership (2026-09-22): the one allowed second LAN scan now
keeps its800ms delay inside the tracked discovery task. The search remains busy
through that delay, so a duplicate Find action cannot start another search;
backgrounding cancels the delay using the same handle. Cancellation and attempt
checks still gate the second pass, and an old pass cannot release a newer one's
busy state. Previously the delay was an untracked Task after discovery had
reported idle. This changes local operation ownership, not probe timings,
network selection, firmware, or measured radio reliability. Controlled empty
discovery tests exercise the delay without sending LAN requests.

Explicit Mac direct-connection cancellation (2026-09-22): CoreWLAN scanning and
association still run off the main actor, but their detached worker now receives
cancellation from its requesting task. Cancellation is checked after location
authorization, at worker entry, between retries and after a scan before starting
association. A completed worker cannot return a success receipt to a cancelled
caller. An already-running synchronous CoreWLAN call cannot be interrupted; this
does not guarantee that an in-flight association never changes Wi-Fi or restore
the original network. Tests use cancellable and non-cooperative local workers,
not CoreWLAN or a real access point. LAN discovery never calls this path.

Join ownership follow-up: the model now injects association I/O so late system
completions can be exercised without changing Wi-Fi. A stale join cannot clear
the current join handle/busy state. Cleanup skips an SSID owned by a replacement
attempt, but releases an obsolete different SSID or an association with no
remaining owner. Backgrounding clears ownership and rejects queued lease joins;
returning to foreground alone does not acquire ownership. This protects model
transitions, not the ordering of OS-level association calls already in flight.

Manual lease verification now uses the same tracked verification handle as
explicit host verification. Backgrounding, caller cancellation or a replacement
join cancels its HTTP wait; attempt-checked completion cannot clear a newer
operation's busy state. Optional reader traffic is drained before verification.
The final timeout fallback also checks cancellation/attempt ownership before
publishing a failure. Verification itself still does not associate Wi-Fi.

Subsequent connection-lifetime correction: manual verification previously had
no generation guard around status acceptance/error/defer and no model-owned
task to cancel on backgrounding. It now tracks and cancels the pending verify,
drains prior background traffic, and only the current generation can accept a
reader or release busy state. LAN backgrounding also stops live traffic rather
than doing so only for a direct connection. Held-response tests demonstrate
that replacing a verification cancels the old request without releasing the
new owner, and backgrounding cannot produce late acceptance/errors. Both pass
alongside the real-heartbeat drain regression, with iOS test and macOS builds
(`.build/verification-lifetime-*`). These newer tests are separate from the
earlier full 99-test run; no physical reader was contacted for this correction.

Foreground follow-up: iOS previously paused heartbeat on backgrounding without
an active-scene path to restore it. The model now tracks background state and
resumes one paced heartbeat for the already-selected LAN reader on foreground.
It does not rediscover, rejoin Wi-Fi, resume a direct lease or send prepared
files automatically. Duplicate scene activations do nothing; demo/no-session
activation stays offline. Background state also blocks optional traffic
resumption from completing operations. Three targeted model tests pass,
including observing the real 15-second heartbeat through a held URLSession
response, with iOS test/macOS builds (`.build/foreground-lifetime-*`). No visual
layout change or physical device validation is implied.

### Current physical baseline (supersedes the bootstrap blockage above)

The one-time SD install was verified through live status as
`1.6.6-dev-main-b8e38e39-sta-recovery-wf3e32596`. The X3 remained in File Transfer
→ Join a Network; neither Mac Wi-Fi nor the reader's position was changed.
A 1024-byte probe returned `OK 1024 48D7F063`.

The complete 6,030,352-byte image then passed wireless reception, final
`OK 6030352 AE2A4752`, and size/CRC-checked HTTP commit to `/update.bin`.
The first unpaced sender was intentionally interrupted to exercise resume;
the next connection returned `RESUME 1187840`. The remaining bytes finished
with `--flow-delay-ms 10`, averaging 10.7 KiB/s for that resumed segment.
This was not a controlled pacing-only comparison: reconnection and heap state
also changed. After publication the same reader/version answered status with
uptime 880 seconds and 9036 bytes free heap, without an intervening reboot.

These are real CLI-driven X3 results, not app-driven device acceptance or an
X4/general-radio sign-off. The image was staged again but not reflashed: it was
already running. New-version remote flashing and automatic Wi-Fi return remain
unverified on hardware. Throughput remains slow; do not call this seamless yet.

For explicitly selected developer installation only, `pocket_put.py --dev-flash`
extracts the new developer version from the image and connects verified publication to the
existing dev endpoint and post-reboot identity/version checking. The developer
boot marker attempts saved Wi-Fi automatically and falls back to the reader's
chooser on failure. Production app/firmware confirmation rules are unchanged.
An old production/audit image still needs a one-time installation path; new
developer automation cannot add an endpoint to already-running old firmware.
This follow-up passed Python recovery/installation-verification tests,
firmware host tests, default/gh_release builds and strict cppcheck using
the current project flags with a local native tool-package substitution after
the package mirror failed. The remote-flash/reboot loop has not been physically tested.

Local verification: 80 iOS unit/integration tests, 166 firmware host tests,
iOS simulator and macOS builds, firmware `default`/`gh_release` builds, and
strict cppcheck against the current project configuration all passed.
The Python suite passes 17 tests. The app now uses TCP_NODELAY and sends
512-byte fragments spaced 10 ms apart inside the unchanged 4096-byte SD-credit
window. Cancellation during a paced window is covered, as is the full paced
6 MB loopback transfer. CLI pacing is explicit with `--flow-delay-ms 10`.
The app suite includes a 6 MB credit-controlled loopback transfer, a 6 MB legacy
resume, unaligned prefixes, invalid ACK rejection, cancellation while waiting
for credit, lost final OK recovery, LAN outage and identity changes.

- Resume state is RAM-only; reader restart may restart the upload at zero.
- A lost commit response is ambiguous and can require retrying the prepared file.
- Frame fetch remains the older paged HTTP contract; firmware closes each
  response. Transfer isolation fixes competition with uploads, not that socket
  churn. A single-response frame transport remains future work.
- Idle heap pressure, X3/X4 radios, private AP, SD durability, physical flashing
  and app-driven end-to-end delivery are hardware gates, not simulator results.
- Firmware staging is separate from installation; preserve reader confirmation.

### Subsequent developer-loop verification — 2026-09-21

Distinct resource-lifecycle firmware `w67fff974` passed full 6030416-byte CLI
upload (CRC 4FFA1BE2), publication, explicit developer flash and automatic
saved-Wi-Fi return, verified by the same reader identity and exact new version.
No post-flash menu action, SD swap, USB or hotspot was required. This supersedes
the earlier unverified remote-flash/rejoin statements for CLI/X3 only.
Two intentional sender restarts resumed the prefix; this was not an automatic
outage-recovery test. The final segment averaged only 2.4 KiB/s. A post-install
64 KiB staged probe passed CRC in 30.44 seconds. Low heap and slow throughput
remain unresolved; physical app delivery, X4 and long-run stability remain gates.
