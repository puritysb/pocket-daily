# Connectivity hardware sign-off

Implementation date: 2026-09-09. The scenarios below are not yet hardware-verified.
Use an actual iPhone and X3; simulator builds cannot verify radios, SD, or flashing.

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
- Reader: Pocket Sync → Nearby Sync. App: Connect directly, then approve pairing
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
- End session after a failed connection must stop background discovery/retries.
- A different HTTP deviceID than the paired reader must prevent transfer. A
  prepared item already bound to a different reader must also be refused.
- Legacy readers lacking deviceID remain usable with fresh staging IDs; do not
  claim authenticated LAN identity or automatic install verification for them.
- A mounted SD folder cannot identify a reader. Check SD-installed versions on
  the reader itself.
- Test both iPhone/iPad and sandboxed macOS. Mac Wi-Fi release must not disconnect
  a different SSID the user selected during the session.

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
