# Pocket Daily TestFlight release test plan

Run this plan against the exact iOS and macOS build `1.0.0 (1)` processed by
App Store Connect. A simulator, development-signed archive, or locally extracted
Store package does not satisfy this gate.

## Evidence header

- Date/time and tester:
- App Store Connect build status:
- iPhone/iPad model and OS:
- Mac model, architecture, and macOS:
- Reader model and hardware revision:
- Reader firmware version and commit:
- `release-evidence.json` SHA-256 values:
- Review-video URL:

Never record the pairing code, temporary hotspot credentials, home Wi-Fi
credentials, device address/serial, personal library, notifications, or private
contact information in screenshots, logs, or video.

## Required matrix

Run every numbered scenario on both iOS/iPadOS and macOS unless a row explicitly
names one platform. Record Pass, Fail, or Blocked with a short evidence reference.

1. **Fresh install and launch**
   - Install from TestFlight, launch twice, and confirm no crash or signing alert.
   - Confirm the app reports version `1.0.0 (1)` and shows its local-first and
     independent-project notices.
2. **Demo isolation**
   - Enter **Explore without a reader** and inspect the clearly labeled X3/X4
     hardware profile and companion controls.
   - Confirm transfer and settings mutation remain disabled in demo mode.
3. **Permission flow**
   - Start with Bluetooth/local-network/location permissions unset.
   - Confirm each request appears only when needed, its purpose text is accurate,
     and denial produces an actionable recovery message rather than a hang.
4. **Reader discovery and pairing**
   - Put the physical X3/X4-compatible reader in Nearby Sync mode.
   - Find and connect through Bluetooth, approve system prompts, and verify the
     displayed reader model and firmware version.
5. **Private Wi-Fi handoff and status**
   - Confirm Bluetooth is released before the reader's temporary Wi-Fi starts.
   - Join through the system Hotspot Configuration prompt, load `/api/status`,
     and verify the UI becomes connected without exposing lease credentials.
6. **Original review EPUB transfer**
   - Transfer `appstore/review/Pocket-Daily-Review-Sample.epub`.
   - Confirm progress completes, transport verification succeeds, and the same
     title opens on the reader.
7. **Settings round trip**
   - Change one harmless setting, apply it, refresh status, and confirm app and
     reader agree. Restore the original value.
8. **Disconnect and recovery**
   - Stop Nearby Sync or power off the reader during an idle connection.
   - Confirm the heartbeat reports disconnection without corrupting state, then
     reconnect and transfer the review EPUB again.
9. **Firmware rejection boundary**
   - Select a non-firmware file renamed to `.bin`; confirm local rejection before
     publication.
   - Select an ESP image for another chip or without Pocket Nearby Sync markers;
     confirm rejection before publication.
10. **Valid firmware staging boundary**
    - Select the exact current firmware artifact whose version is recorded above.
    - Confirm local structure/checksum/digest/identity validation and transfer as
      `/update.bin`, then cancel at the reader confirmation. Do not flash during
      this release test or review recording.
11. **macOS file and SD access**
    - Select a book with the system file picker and verify the sandbox bookmark
      permits the operation after relaunch.
    - With a test SD card mounted, copy the review EPUB and a valid firmware image;
      confirm the expected layout and that existing files are not overwritten.
12. **Privacy and network observation**
    - Confirm the app works without an account and sends no analytics or cloud
      traffic. Expected traffic is limited to the physical reader's local link.
    - Export diagnostics explicitly and inspect the file for secrets before it is
      attached anywhere.

## Release decision

The build is releasable only when:

- all applicable scenarios pass on one current iPhone or iPad and one supported
  Mac architecture;
- App Store Connect reports both uploaded builds as eligible for TestFlight;
- no launch, crash, pairing, transfer-integrity, permission, or reconnect defect
  remains open;
- the physical-reader review video follows
  `appstore/review/REVIEW_VIDEO_CHECKLIST.md` and its URL is present in Review
  Information; and
- the review contact, privacy answers, age rating, content rights, screenshots,
  and manual-release selection are confirmed in the live app record.

If any row is Blocked, do not submit for review. Record the exact device, OS,
reader version, step, visible error, and supporting log before changing code.
