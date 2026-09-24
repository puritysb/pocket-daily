# Pocket Sync sessions

Implementation update: 2026-09-24. Local verification is recorded in
PROJECT_MEMORY.md; physical X3/X4 acceptance is not implied.

## One editor, two explicitly selected connections

| Situation | Reader entry | App action | Network effect |
| --- | --- | --- | --- |
| Shared Wi-Fi | Pocket Daily → Sync → Same Wi-Fi | Find on same Wi-Fi | Apple device stays on its current network |
| No router or internet | Pocket Daily → Sync → Direct connection | Connect directly, confirm, pair | BLE supplies a temporary reader Wi-Fi lease; Apple device joins it |

These names are Pocket Daily-specific. Older builds call them Join a Network
and Nearby Sync, respectively; the app retains a short compatibility note.
Pocket Sync's connected screen directs users to the app, not a browser QR
whose target is status JSON. The separate File Transfer browser flow is
unchanged. No network is changed merely by showing these choices, and no
automatic fallback from shared Wi-Fi to direct connection is permitted.

The existing BLE control plane and iOS NEHotspotConfiguration/macOS CoreWLAN
association are reused. BLE is released before the reader starts its private
AP. No account, cloud service or router is required for that direct path.
Prepare cloud-hosted files before switching networks. The Mac's usual Wi-Fi
internet may be unavailable during a direct session; concurrent internet is
not promised. No automatic LAN-to-hotspot fallback is permitted.

## Resource ownership

The firmware's existing COMPANION (shared network) and POCKET_SYNC (private
AP) profiles now both refuse WebSocket listener startup and resumption,
independently of free heap and board model. Their status advertises poll-only
operation and does not automatically offer preview/crash downloads or inspect
those SD files. This avoids optional listener/client/frame traffic competing
with content and firmware transfers. Explicit diagnostic endpoints are not
removed. File Transfer keeps its browser-compatible behavior for recovery.

Theme list/apply registration is also independent of screen streaming now.
Previously private AP advertised `uiPacks:true` but omitted both endpoints;
the new firmware registers them for all profiles. A source-boundary host test
guards their unconditional registration, and Swift fixtures cover poll-only
X3/X4 advertisements on both STA and AP. These do not replace HTTP hardware tests.

This is a bounded change to the existing server, not a new TCP/IP stack or
proof that the prior intermittent TCP failures are fixed. HTTP and the port-82
stream remain shared tested primitives; no second server, buffer or worker was
added. Remaining lower-level failures need evidence from the dedicated profile.

## Content and firmware remain separate

The sibling's developer-update path now preserves shared-Wi-Fi Sync versus
File Transfer using a verified one-shot boot marker. Nearby/AP returns to the
matching chooser for fresh explicit pairing, never silently to home Wi-Fi.
Old initiating firmware only writes the legacy File Transfer marker, so the
first upgrade from it cannot recover the missing origin. This working-tree
change is installed in we46ca975 but origin-aware return from that build is
not yet hardware-verified; see sibling
`docs/dev-update-return.md`. App wire requests and production firmware
confirmation are unchanged.

- Content and theme edits use the existing verified staging/commit protocols.
  Cards require revision-bound activation and redraw receipts. Presentation
  stays inside the server activity so viewing cards does not end the session.
- Firmware uses the same transport to stage a validated `/update.bin`. Staging
  is not installation. The existing reader confirmation and post-reboot version
  check remain mandatory; live editing never flashes automatically.
- BLE failure before a lease revokes the pending direct request, allowing LAN
  discovery or another explicit direct attempt without changing Wi-Fi. A late
  BLE failure must not revoke an acquired lease or in-flight association.

## Physical acceptance gate

Historical X3 boundary (before we46ca975): dedicated Sync physically completed one
card's durable activation, but presentation is rejected with HTTP 503 before
font preparation because of the firmware's 16 KiB / 4 KiB-largest-block guard.
A display-only retry after idle still failed; no files or activation were
resent. Status partially recovered from 11,856 to 14,212 free bytes. These are
HTTP-handler samples, not idle heap or largest-block measurements.

The Swift presenter now retains the original POST error when its read-only
recovery query also fails. A successful recovery receipt still resolves a lost
POST response; cancellation propagates and no POST is repeated. This improves
diagnosis only; it does not fix the device's rendering resource budget.

The sibling working tree now queues verified metadata inside the HTTP callback
and prepares the card/font only after request cleanup and upload reply grace.
New request/upload processing cannot overlap the pending paint's font budget.
The old snapshot is released before the unchanged16KiB/4KiB cold admission.
The additive schema1 presentation receipt exposes `failure` and sampled `heap`
and `block`; queued still does not mean rendered. Swift maps memory/preparation
failures to distinct explanations, accepts old receipts, and never resends on
a failed receipt. Unknown reasons fail generically. Deferral alone proved
insufficient; the later route-lifetime change removed persistent per-endpoint
server allocations. The SDK's
1,436-byte request receive buffer is only one allocation being separated, not
a claim of measured total savings.

Current X3 result (2026-09-24, we46ca975): one existing-card presentation
returned rendered/none with admission heap17,996B/block12,788B, and the user
confirmed the card is visible. No content resend or reconnect was needed.
HTTP reads timed out during preparation before recovering; repeated Apply,
responsive preparation, private AP and X4 still require acceptance. The new
connection labels/guidance are a subsequent UI change, not installed yet.

Run both connection rows on X3 and X4 with iPhone and Mac. Do not claim support
is validated from host tests or simulator association mocks.

1. Verify the installed artifact and select Pocket Sync, not File Transfer.
2. Confirm poll advertisement, no WS listener, memory/largest-block headroom,
   working buttons, and status responses during an idle session.
3. Apply one small card; require activation and redraw confirmation. Edit it
   and apply again in the same session, without leaving the reader screen.
4. Stage a validated firmware image with size/CRC verification. Install only
   with explicit confirmation, then verify the exact running version.
5. Exercise cancellation, Wi-Fi loss, app background, failed pairing, and
   explicit session end; preserve drafts and pending activation outcomes.

Stop at the first failed step and record its exact phase. Do not loop firmware
uploads, swap networks automatically, or equate responsive buttons with a
healthy radio. A bootstrap installation is still required to test new firmware.
