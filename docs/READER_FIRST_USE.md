# Reader first use and reading-first defaults

## Product structure

The reader works without the companion. Its Home menu owns Library, file
transfer and system Settings, including firmware management. Pocket Daily is
its reading dashboard: the current book comes first, followed by cards the
user deliberately adds. Articles keep their existing shortcut. Sync connects
the companion; it is not the only way to add a book.

A fresh X3 installation offers Bluetooth setup once, before showing the
reading dashboard. Its pairing code is visible immediately. **Read offline**
skips setup; five minutes without an authenticated connection also returns to
reading. Existing settings, sleep wakes, crash recovery and developer return
routes take precedence; upgrading an existing installation does not force
onboarding. Settings must save successfully before the first-use offer starts.

In the app, **Set Up Reader** is the primary first-connection action:

1. Discover and pair the nearby reader using its displayed system pairing code.
2. Fill the Wi-Fi name with **Use Current Wi-Fi**, or enter it manually.
   macOS may offer the saved password through user-approved keychain access;
   iOS requires manual password entry. Permission denial keeps manual input usable.
3. **Save and Connect** transmits credentials over authenticated BLE. The reader
   joins and saves the network only after successful association. The app
   verifies the matching result and discovers the reader on the current LAN.
4. Add a DRM-free EPUB in Library and send it, or use existing books on the SD.

No initial reader-side SSID/password entry or IP address is part of this path.
System Bluetooth/pairing and Wi-Fi-name permissions are not bypassed. On X4,
or if first setup was skipped, open Pocket Daily → Sync → Direct connection. **Find on Same Wi-Fi** and direct connection without a router remain
available alternatives. No automatic firmware flashing is introduced.

## Defaults and optional content

- Home retains a Reading page even before any book has been opened. The empty
  page explains that Library is the next action; Confirm opens Library.
- Sleep shows the current book's reading section. Without a book, it retains
  the same meaningful empty slot. Its status is **Sleeping**, not Powered off.
- Weather, events and daily vocabulary default off. Existing explicitly saved
  profiles are preserved; these defaults apply to missing/new profiles.
- Cards start empty. **Add Reading Prompt** inserts one original, editable
  reflection question only when chosen. Saving is local; Apply remains the
  explicit device publication step. Demo mode cannot mutate or publish.
- The original Welcome book explains reading, adding EPUBs, the standalone
  reader menu, optional cards and firmware confirmation. It is useful content
  available before a reader is paired; it is not fabricated personal data.
- Japanese vocabulary with Korean meanings is a clearly described optional
  deck. The firmware's existing SD learning pack and attribution remain the
  source of truth. It is not silently enabled or automatically sent.

Additional packs should have a stated audience/language, a preview, byte size,
version, license/attribution and an explicit Add/Send action. Good first packs
are original reading reflections or a deliberately chosen language course.
A pack catalog, pack installer and automatic recommendations are **not** part
of this change. The existing learning pack is SD-installed; do not describe a
retired provider's network endpoint as a current app feature.

## X3 wake transition

The retained closed-book tab opens once and gives way to the real page. The
firmware draws it locally with vector primitives and its existing framebuffer;
there are no downloaded frames, app/BLE dependency or animation dwell timers.
It replaces the old wake cue refresh and uses FAST on X3. A button held before
the refresh bypasses the cue and requests the current book (while preserving
recovery and held-Back navigation). The display BUSY-wait observer also latches button contacts during the waveform
and requests the book immediately after it completes. An in-flight panel
waveform is not cancellable; this is not a promise of zero physical refresh
latency. Holding OK during physical wake was user-verified on X3: the cue was skipped
and the same body returned. A second attempt ended before a mid-cue press;
input specifically during the BUSY waveform remains unverified.

## Verification boundary

Host tests cover reading-first defaults, optional content and distinct,
reversible wake poses. The Mac/X3 screen suite now also records a timer wake
through the real splashless path, downloads the wake framebuffer, checks the
unchanged body and changed cue, and requires a measured refresh of 1..1500 ms.
Run IDs and negative controls reject stale/missing evidence. Captures prove the
rendered framebuffer, not optical panel quality. Timer wake does not prove the
physical power-button gesture, nor a button press during a waveform.

Fresh-settings Mac/X3 acceptance on 2026-10-13 completed automatic BLE discovery,
system passkey pairing, user-approved keychain autofill, BLE credential transfer,
a matching saved receipt and automatic LAN rediscovery, followed by sending the
Welcome EPUB. Existing macOS pairing had to be removed after the reader reset;
a genuinely new customer has no such stale bond. Root books/fonts and OS
permission decisions were retained; this was not a hardware flash erase.
Evidence is in the firmware checkout's ignored `build/first-ble-onboarding/`.
Held-button skip passed by physical user observation with the normal Mac app
closed. In-waveform timing remains unverified; the cue ended before the user
could press in the second trial. No animation delay was added for the test.

## Firmware-aware onboarding decision — 2026-10-13

Do not assume CrossPoint is the factory firmware. Ask which software is on the
reader, or explain where to check Settings/About. An unknown reader should see
compatibility help before repeated Bluetooth scans.

| Starting state | Customer route | What the app may promise |
| --- | --- | --- |
| Pocket Daily on X3, fresh settings | Automatic setup screen → app Set Up Reader → system pairing → Wi-Fi details → Save and Connect | Our authenticated BLE setup and identity-checked LAN discovery; offline skip remains available |
| Pocket Daily on X4, or setup skipped | Sync → Direct connection, then app Set Up Reader; alternatively Same Wi-Fi | Existing supported connection routes; do not promise X3-only automatic first-boot setup or standby behavior |
| Compatible CrossPoint build | Reader File Transfer → Join a Network; app Find on Same Wi-Fi | Only capabilities actually returned by that version; no assumption of our BLE provisioning, home/sleep cards or position extension |
| Xteink factory firmware | Explain direct app connection is not supported; offer app-only reading and manufacturer instructions | No stock BLE provisioning, manufacturer-cloud access or wireless bootstrap claim |
| Unknown firmware / model / locked unit | Identify exact model, software version and installation eligibility first | No automatic installation or generic X3/X4 binary recommendation |

The supported starting point for full companion functionality is **Pocket Daily
firmware**. Installing ordinary CrossPoint first is not inherently required on
an eligible unlocked device, but first installation and recovery must be verified
for the exact device and artifact before a public Pocket Daily installer is offered.
The app's firmware-file staging flow is not a factory-firmware installer.

Current official CrossPoint guidance documents computer/USB web installation,
and warns that its unlocker supports only CrossPoint and CrossInk on USB-locked
units. Therefore **do not recommend using that unlocker to install Pocket Daily**,
or assume that first installing CrossPoint makes a locked unit safe for our fork.
Direct customers with locked/uncertain units to their seller or the upstream
instructions; offer app-only reading meanwhile. X4 (ESP32-C3) must not be confused
with X4 Classic/V2 or X4 Pro (ESP32-S3).

Sources checked 2026-10-13:
- [CrossPoint official installation and locked-device warning](https://github.com/crosspoint-reader/crosspoint-reader#install-firmware)
- [CrossPoint HTTP contract](https://github.com/crosspoint-reader/crosspoint-reader/blob/develop/docs/webserver-endpoints.md)
- [Xteink model-specific guides](https://www.xteink.com/pages/user-guide)
- [Xteink X3 product and third-party restrictions](https://www.xteink.com/products/xteink-x3)

These sources establish documented routes, not physical acceptance of stock or
current upstream builds by Pocket Daily. Stock X3/X4 and upstream-version
compatibility remain separate device/version tests. No stock firmware was
installed over this development X3 as part of the onboarding rehearsal.
