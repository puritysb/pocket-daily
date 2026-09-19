# App Review notes

Pocket Daily is a local-first companion for separately obtained X3/X4-class e-paper hardware running Pocket Daily or compatible CrossPoint-based firmware. It does not support a manufacturer's factory firmware or cloud service. No login, purchase, subscription, or remote service is required.

## Review without hardware

1. Launch Pocket Daily.
2. In the **DEVICE** card, choose **Explore without a reader**.
3. Inspect the X3/X4 hardware profile. It is explicitly labeled as a profile because no reader frame is available in hardware-free mode.
4. The settings card is populated in demo mode. Applying settings and sending files are intentionally disabled because no physical reader is connected.
5. Choose **Exit demo** to return to normal discovery.

The submitted screenshot build can also be launched with `--demo` by the development team; reviewers do not need launch arguments because the same mode is visible in the interface.

## Live hardware flow

1. Prepare a file with Choose file before switching networks. Firmware requires
   acknowledgement and is validated before entering the offline queue.
2. For shared Wi-Fi, open File Transfer → Join a Network on the reader and
   choose Find & Connect. This requests local-network access without BLE or
   automatic Wi-Fi switching.
3. Away, open Nearby Sync on the reader (new firmware has a transport chooser),
   choose Connect directly in the app, and confirm the Wi-Fi transition. BLE
   pairing supplies the temporary credentials. No router or internet is required.
4. Choose Send prepared files and keep the iPhone app open. Direct sessions defer
   preview/crash requests to preserve reader memory. Pending files survive an
   interruption; resume depends on firmware capability and retained session state.
5. Successful direct batches release the temporary connection. New firmware also
   exits the private session. Firmware still requires reader-side confirmation;
   reconnect to verify the version for an identified reader.

The app does not read location coordinates. On supported Apple OS versions, location permission may be requested only because the system gates Wi-Fi hotspot configuration behind that permission. The bundled privacy manifest declares app-only UserDefaults and user-selected file-metadata access; the app does not track or collect data.

## Reviewer attachment still required

Before submission, attach a short, unedited video showing one physical reader completing discovery, transfer, and reader-side confirmation. Follow [REVIEW_VIDEO_CHECKLIST.md](REVIEW_VIDEO_CHECKLIST.md). Replace the placeholder video URL in App Store Connect review notes.
