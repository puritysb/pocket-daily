# Connectivity hardware sign-off

For repeatable app/firmware development, start with
[Reader development from the app repository](DEVELOPER_PIPELINE.md). It links
the shared hardware scenarios, Same-Wi-Fi runner and per-run evidence.

## App-requested BLE wake — 2026-10-09 (local experimental build)

`ReaderWakeConnector` serves an explicit Connect operation for the remembered
bonded reader. It checks protocol 1, matching reader identity and `WAKE1`, sends
one `START_WIFI <8 uppercase hex digits>` and requires the matching application
acknowledgement. A write acknowledgement alone is not success. Cancellation,
timeout and an ambiguous/lost reply do not replay the wake command. Subsequent
LAN discovery can still recover the reader after a lost reply.

Connect checks the current LAN first. An unreachable remembered reader can be
woken over BLE and then accepted on its saved Wi-Fi only with matching identity.
Explicit Connect sheets start this automatically for a remembered bonded reader;
Manage Reader alone does not start work. Quiet position exchange never raises
Wi-Fi. The foreground transport has no CoreBluetooth restoration identifier,
leaving restoration owned by the existing background reading link. ReaderWorkLane
suspends that quiet link while the foreground operation owns the connection.

The reader requires the opt-in X3 `ble_standby` firmware, an existing bond,
saved reachable Wi-Fi, enabled reading sync and battery above 10%. It uses
controller modem sleep plus automatic light sleep, not BLE wake from deep sleep.
Default/release firmware and X4 retain bounded BLE windows. No automatic hotspot
or Apple-device network change is introduced. Initial pairing and OS permission
remain one-time setup. Physical iPhone and X4 acceptance and current measurement
are still outstanding.

First physical Mac/X3 trial succeeded: actual Mac UI progressed from Bluetooth
wake to joining Wi-Fi and connected; the reader recorded `app-wifi`, 611 actual
light-sleep exits / 13,888 ms asleep during 17,607 ms standby and automatically
returned to STA. Minimum sampled BLE heap was 64,564 B. Firmware evidence and
artifact identity are in the sibling `docs/ble-standby-review.md`; device IDs stay
in ignored local evidence. A separate file-inventory error was observed after
connection and is not counted as a successful content transfer.

Four connector tests and the existing transport/protocol suites passed (134
tests on iOS Simulator); signed macOS and iOS builds passed for the transport
change. This does not establish suspended iOS wake behavior or measured energy.

Final firmware `8925b142-ble-standby-wd4168ca4` additionally passed two trials
starting sleep from connected Same Wi-Fi. In the last, the Mac app was restarted
during 80.8 s standby, and one Connect Reader click woke and connected the X3.
The reader recorded 64.8 s actual light sleep and 60,936 B minimum BLE free heap.
Final signed Mac and iOS builds include automatic Connect-sheet startup and
paired-reader disconnect wording that no longer instructs a reader-menu visit.
Five app-wake trials passed across the two images; the final two cover this
firmware's Wi-Fi-entry path. Physical iPhone, X4 and energy gates remain open.

## Current installed baseline — 2026-09-22

The X3 is confirmed on `1.6.6-dev-main-b8e38e39-sta-recovery-w998f2f9d`
after the already completed SD bootstrap. Keep this image and the existing
File Transfer → Join a Network connection fixed; do not use the historical
preflight or failed-upload notes below as a reason to install it again.

A subsequent single read-only `/api/status` request returned HTTP 200:
TCP connect 0.093414 s, first byte 0.118271 s, total 0.118802 s. Status reported
uptime 1838 s, RSSI -45 dBm, free heap 9100 B, `diagnosticsAffordable:false`,
stream port 82 with resume/window 4096, and Live Studio push on port 81.
No payload, firmware upload, reboot, mode change or reconnect was attempted.
Device identity matched the previously observed reader; identity is omitted
from this tracked record.

This supersedes a claim of persistent unreachability, not the earlier observed
timeouts. The failure is intermittent; one healthy control request neither
establishes sustained transfer reliability nor isolates radio/heap/driver causes.
The modified Swift app was not used for this curl observation, so the response
must not be credited to its HTTP scheduling changes.

One subsequent 1 KiB CLI trial with developer counters passed its two status
checks but timed out reading the baseline statistics response's HTTP chunks.
It stopped before staging-name creation or any port-82 payload. No file was
created, committed or deleted, and no retry followed. This isolates that trial
to a diagnostic-response failure; it does not establish a content-transfer
failure. Details: sibling `docs/TRANSFER_BENCHMARK.md`, frozen-baseline follow-up.

A separate single 1024-byte trial, omitting only the optional diagnostic API,
then passed stream receipt (`OK 1024 B70B4C26`), publication, downloaded SHA256,
same-reader/version/uptime checks and cleanup. The unique inert test file was
deleted; firmware and connection mode were unchanged. Evidence: sibling
`build/frozen-baseline-plain-1k.log`. Upload including setup took 1.1141 s,
commit 1.4534 s and readback 1.3595 s. This proves the small-file CLI path on
this baseline, not app delivery, multi-window flow control, resume or sustained
large-file reliability. The diagnostic failure is not a data-path verdict.

The next single 16 KiB trial passed three intermediate ACKs, final stream CRC
(`E81722F0`) and publication, but HTTP body readback timed out. Therefore its
downloaded SHA and end-to-end acceptance did not pass. Identity-checked cleanup
deleted the generated file without a reconnect. The failed readback uses
Content-Length, unlike the failed chunked diagnostic endpoint. Evidence:
sibling `build/frozen-baseline-plain-16k.log`. Multi-window reception is now
observed; outbound HTTP delivery is the immediate investigation boundary.

One follow-up with partial-read observation again passed 16 KiB upload/commit,
then received 8192 bytes in eight reads before EOF at 11.7182 s. Exact-size/SHA
validation rejected it; cleanup succeeded. This is not another upload failure.
Advertised response length/prefix equality were not captured on that run;
the local benchmark now records them for any future failure. No firmware or
connection changes. Evidence: sibling `build/frozen-baseline-read1-16k.log`.

Final instrumented observation: another 16 KiB upload/CRC/commit passed;
download declared16384 bytes but returned only6144 matching the original
prefix, then timed out at41.2737s. Cleanup passed. Evidence: sibling
`build/frozen-baseline-prefix-16k.log`. This is variable partial HTTP delivery,
not a fixed8KiB limit or malformed uploaded prefix. Stop identical repeated
trials; no firmware or connection changes have been made to resolve it.

Distinct receive-buffer experiment: requested4096 only on the Mac download
socket, but OS reported effective35900. Thus the intended 4KiB condition was
not established. 16KiB upload/CRC/commit passed with an11.0383s maximum ACK
delay before that option was applied; download returned10240 correct-prefix
bytes then EOF. Cleanup passed. Evidence: sibling
`build/frozen-baseline-rcvbuf4k-16k.log`. Do not conclude stalls are exclusively
HTTP outbound or promote the experimental option to the app. No firmware,
reconnect or global OS network setting was changed.

Latest local app verification: 99 unit/integration tests and iOS/macOS builds
pass (`.build/http-serialization-*`). The earlier 7 UI-test result below has not
been rerun for the latest non-UI changes. Physical app delivery and X4 remain
unverified.

## Offline artifact preflight — 2026-09-22

At this earlier checkpoint, full local regression passed 91 unit/integration and 7 UI tests
(`.build/current-full-regression.log`). In particular, the 6 MiB loopback
flow-control test passes; this does not measure the physical reader's throughput.
Current production firmware builds and passes the same Swift validator, with
developer flash/transfer-counter markers absent. No release is authorized or
hardware sign-off implied by those results.

Before staging a developer image, run the shipping Swift validator against the
actual built binary, asserting its expected embedded version:

```sh
bash scripts/validate_firmware.sh /absolute/path/to/image.bin EXPECTED_VERSION
```

This compiles `Sources/FirmwareImageValidator.swift` with a small command-line
driver and checks chip, segments, checksum/digest, product markers and version.
It prints byte count and SHA-256, explicitly `installed:false`; it never connects
to a reader or writes the image. Temporary compiled tooling lives under `.build/`
and is removed after the check. A version mismatch or invalid/missing file exits
nonzero. This preflight does not replace target identity or hardware checks.

The 6,036,272-byte `sta_recovery` image ending `w998f2f9d` passed this check;
SHA-256 `2fb59ea48580bce5381f276522da37f97bca054341314e58e5792db680250c23`.
Wrong-version and missing-file invocations failed as expected. This newer image
includes transfer counters and subsequent pack/queue fixes. It was not installed
at the time of that offline check; the completed SD installation and current
live confirmation above supersede that old state. The previous `w11d630ad`
wireless delivery failed while the reader ran `w67fff974`. See sibling
`docs/TRANSFER_BENCHMARK.md` for that historical failed attempt.

## Latest CLI/X3 developer-loop result — 2026-09-21

Companion discovery test follow-up: real IO is now behind `ReaderDiscoveryIO`.
A DEBUG-only empty-IO fixture exercises the actual no-reader retry/error UI
without assuming the user's LAN has no devices. The repaired full test run
passed 88 unit/integration and 7 UI tests; macOS Debug/Release builds passed.
Cancellation/replacement/background guards prevent stale discovery results from
changing the active attempt. These are simulator/host results, not physical
LAN latency, X4 or app-to-device transfer sign-off.

Distinct firmware `1.6.6-dev-main-b8e38e39-sta-recovery-w67fff974` passed full
wireless upload, CRC-checked publication, developer flash, automatic saved-Wi-Fi
return and same-reader exact-version verification. No post-flash menu action,
SD swap, USB or hotspot was needed. Post-install 64 KiB reception also passed
CRC. This does not sign off app-driven delivery, X4, production confirmation,
long-run stability or performance: the probe averaged only about 2.2 KiB/s.
Details: sibling firmware `docs/CORE_CONNECTIVITY_REPAIR.md`.

## Earlier acceptance checklist

Implementation date: 2026-09-09. The scenarios below are not yet hardware-verified.
Use an actual iPhone and X3; simulator builds cannot verify radios, SD, or flashing.

## Transfer isolation and flow control — 2026-09-21 acceptance

- Use Pocket Sync → Join a Network for the new app-only STA profile; confirm
  preferences, content and UI packs on a clean SD card. File Transfer retains
  browser functionality and is the bootstrap path for older firmware.

- On updated firmware, status must advertise `uploadStreamWindow:4096`.
  Send a 6 MB image and a UI pack from the updated app; verify final size/CRC,
  pack apply/revert, and that firmware remains staged until reader confirmation.
- While sending, no screen-live/preferences/heartbeat requests should compete
  with payload. The reader must not run gateway probes during payload flow.
  After completion, WS may resume after its five-second cooldown; the app's
  next healthy heartbeat reconnects it if advertised and resources allow.
- Drop a transfer at an unaligned offset and just after final payload delivery.
  Same-session resume must retain the accepted prefix; a reader reboot is
  explicitly permitted to restart at zero. Lost commit responses are still an
  unresolved delivery ambiguity and can require retrying the prepared file.
- During LAN recovery, missing status replies must delay bulk retries; a
  changed or missing previously known device ID must stop them.
- Test a router whose TCP admin port refuses connections: an RST is healthy.
  Local socket/OOM errors must not count as proof of a deaf radio.
- Capture heap/maximum block and transfer duration on X3 and X4. The bounded
  sender reduces queued payload; it does not prove that idle radio starvation,
  flash installation, or private-AP behavior is fixed.

## Shared network

- Reader: File Transfer → Join a Network, or Pocket Sync → Join a Network on
  the updated firmware. Previously saved Wi-Fi credentials should reconnect.
- App: Find & Connect must never start Bluetooth pairing or change Wi-Fi.
- Prepare and send content, then firmware. The latter must remain staged until
  confirmed on the reader. Reconnect to check the identified reader's version.

## Away, with no router or internet

- Prepare several files while internet is available, including a cloud-provider
  file and at most one firmware image. Disconnect internet and relaunch the app;
  all files must still be present in Ready offline.
- Reader: Pocket Sync → Nearby Sync. App: Connect Directly, then approve pairing
  and Wi-Fi switching. Cancelling the app confirmation must start neither action.
- Send the batch. Content is published before firmware. Optional preview/crash
  requests must not start automatically. Record X3 free heap, largest block,
  transfer duration, and any reset/watchdog diagnostics.
- During a large transfer, use Pause transfer, lock the iPhone, and separately
  switch apps. Pending files must remain local. Return, Reconnect directly, and
  send again. Same-session supported readers should resume; after reader reboot,
  restarting at zero is expected and partial files must remain unpublished.
- Successful direct batches must release the app's temporary Wi-Fi configuration.
  Updated private-AP firmware should return to Pocket Daily after its session-end
  response. Older firmware needs manual exit or idle expiry. Verify the OS's
  actual return to usable networking; the app does not guarantee the previous SSID.
- Install staged firmware using the reader's own confirmation. Reopen Sync after
  reboot and reconnect directly: the app should confirm the installed version for
  that reader, without any home network.

## Failure and identity cases

- Wrong passkey, denied hotspot join, expired AP lease, SD write failure, and a
  user-initiated Wi-Fi change must leave an actionable status and prepared files.
- End Session after a failed connection must stop background discovery/retries.
- A different HTTP deviceID than the paired reader must prevent transfer. A
  prepared item already bound to a different reader must also be refused.
- Legacy readers lacking deviceID remain usable with fresh staging IDs; do not
  claim authenticated LAN identity or automatic install verification for them.
- A mounted SD folder cannot identify a reader. Check SD-installed versions on
  the reader itself.
- Test both iPhone/iPad and sandboxed macOS. Mac Wi-Fi release must not disconnect
  a different SSID the user selected during the session.

## Experimental STA recovery — 2026-09-21

Physical X3 status confirmed the SD-installed
`1.6.6-dev-main-b8e38e39-sta-recovery-wf3e32596` image and 4096-byte upload
windows. Over File Transfer → Join a Network, the CLI passed a 1024-byte probe
and a 6,030,352-byte firmware staging run (CRC AE2A4752, validated HTTP commit).
Intentional interruption resumed at 1,187,840 bytes; paced completion averaged
10.7 KiB/s for the remaining segment. Post-transfer status retained identity,
version and increasing uptime. No USB, hotspot or reader relocation was used.
This is CLI staging and SD-install verification only: app-driven transfer,
new-version remote flash/rejoin, X4 and sustained idle/repeated-transfer
acceptance remain open. See [TRANSPORT_RELIABILITY.md](TRANSPORT_RELIABILITY.md).

## Observed STA staging — 2026-09-09

An actual X3 running 1.4.1-dev-main-551001f5-wacf0cb93 received the locally
built 1.4.1-dev-main-fa92806c-wf9376b5a through scripts/pocket_put.py over STA.
The first socket broke after the sender had queued 3,293,184 bytes; the reader
remained responsive without reboot. A retry received RESUME 3166028 and finished
in 355.6 seconds. Final reader reply: OK 6022752 51C1E4B5. Commit returned HTTP
200 with the same size/CRC and published /update.bin.

This verifies script-driven staging and same-session resume on the old STA
firmware only. Transfer was slow and interrupted; it is not a throughput sign-off.
New firmware installation, updated-app transfers, direct AP and iPhone background
recovery still require verification. Image SHA-256:
213477cb614e65f0573fe253778b8fcf06e5a3752c74b9a800ad24e5827c4ca5.

## Installation confirmed — 2026-09-09

After the user confirmed reader-side installation, a fresh /api/status response
reported 1.4.1-dev-main-fa92806c-wf9376b5a, exactly matching the staged image.
The X3 was in STA mode, uptime 31 seconds, reset reason software restart, with
16,140 bytes free heap. The new deviceID field was present; sessionEnd was false
as required for STA. Port 82 and stream resume remained advertised.
This confirms installation and post-reboot LAN status, not direct-AP or iPhone
transfer behavior.

## iPhone file-picker search — 2026-09-10

The user reported that typing in Recents search briefly closed and reopened the
picker. Pocket remained running during reproduction; no corresponding new app
crash report was found. The underlying cause was not established from logs.
iOS now hosts one UIDocumentPickerViewController in a full-screen presentation,
preserving its controller during SwiftUI updates and processing selection only
after dismissal, before any firmware confirmation. macOS retains fileImporter.
The modified build was installed on the paired iPhone. iPhone and iPad simulator
search-retention tests passed. On 2026-09-11, the user reported that the issue
appeared resolved on the physical iPhone. This is user-reported verification of
the picker change; the underlying cause remains unconfirmed. Subsequent file
preparation, direct-AP transfer, and session cleanup still need verification.

## Replacing prepared files during a direct session — 2026-09-11

The user connected directly, removed the prepared queue, and could not proceed.
Both the picker and model had prohibited preparation during any direct session,
while queue removal remained enabled. Preparation now remains available while
idle, including during a direct session; cloud-only files may require ending the
session and downloading before reconnecting. Removing queued files preserves the
connection and resets transfer progress. Successful removals are reflected one by
one so a later filesystem error does not leave already-deleted entries queued.
A model regression test prepares, removes, and prepares again during direct
session state without invoking Bluetooth/Wi-Fi. All 45 unit tests and both
platform builds passed. The signed update was installed on the paired iPhone;
automatic launch was blocked by the device lock. Actual connected-device
replacement still needs testing.
