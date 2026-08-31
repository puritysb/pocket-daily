# App Review notes

Pocket Daily is a local-first companion for separately obtained X3/X4-class e-paper hardware running Pocket Daily or compatible CrossPoint-based firmware. It does not support a manufacturer's factory firmware or cloud service. No login, purchase, subscription, or remote service is required.

## Review without hardware

1. Launch Pocket Daily.
2. In the **DEVICE** card, choose **Explore without a reader**.
3. Select **Today**, **Japanese**, **Books**, and **Firmware** to inspect the four preview surfaces.
4. The settings card is populated in demo mode. Applying settings and sending files are intentionally disabled because no physical reader is connected.
5. Choose **Exit demo** to return to normal discovery.

The submitted screenshot build can also be launched with `--demo --section=today` by the development team; reviewers do not need launch arguments because the same mode is visible in the interface.

## Live hardware flow

1. On the compatible reader, open Pocket Daily and choose Nearby Sync.
2. In the Apple-platform app, choose Find & Connect.
3. Bluetooth is used for nearby discovery and pairing; a temporary local Wi-Fi link carries books, study packs, settings, and firmware files.
4. Firmware is only staged after a warning sheet. Installation requires a separate confirmation on the reader.

The app does not read location coordinates. On supported Apple OS versions, location permission may be requested only because the system gates Wi-Fi hotspot configuration behind that permission.

## Reviewer attachment still required

Before submission, attach a short, unedited video showing one physical reader completing discovery, transfer, and reader-side confirmation. Follow [REVIEW_VIDEO_CHECKLIST.md](REVIEW_VIDEO_CHECKLIST.md). Replace the placeholder video URL in App Store Connect review notes.
