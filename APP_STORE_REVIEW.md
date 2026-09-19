# App Store review notes

## Product identity

Pocket Daily is an independent, account-free companion for X3/X4 hardware that
has Pocket Daily or compatible CrossPoint-based firmware installed. It is not an
official Xteink or CrossPoint Reader application, does not support the
manufacturer's factory firmware or cloud service, and does not use manufacturer
logos, product photography, manuals, application assets, or firmware binaries.

References to X3, X4, CrossPoint Reader, and Xteink are limited to factual
compatibility and open-source attribution. They do not imply affiliation,
sponsorship, or endorsement.

## Review setup

The app has an explicit, local demo mode for review without an account or
reader. In the DEVICE card, choose **Explore without a reader**. Without a
reader the central rendering is explicitly labeled as a hardware profile. A
live connection made from Pocket Daily Nearby Sync loads the exact e-paper
frame captured immediately before the reader opens Sync. Demo settings are
populated, but file transfer and applying settings are disabled so review data
can never be mistaken for a connected device.

Live hardware actions require a compatible reader:

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

The developer should attach a current end-to-end physical-reader video following
[`appstore/review/REVIEW_VIDEO_CHECKLIST.md`](appstore/review/REVIEW_VIDEO_CHECKLIST.md)
and offer review hardware if requested. No backend, login, purchase, or external
account is required.

## Firmware safety boundary

The app does not download or silently install executable code. A firmware file
must be selected by the user. Before transfer, the app discloses that factory
firmware is unsupported and that custom firmware can affect device support or
warranty. The app then stages the file as `/update.bin`; installation requires a
second explicit confirmation on the reader, which validates the image again.
Before staging, Pocket Daily rejects an image unless its ESP32-C3 header,
segments, checksum, SHA-256 trailer when present, and Pocket Nearby Sync product
identity all validate locally.

## Privacy

Bluetooth, local-network, and location purpose strings describe the direct
reader connection. Location is used only where the operating system requires it
to inspect or join nearby Wi-Fi; coordinates are neither read nor transmitted.
The bundled privacy manifest declares app-only UserDefaults and user-selected
file-metadata access; the app does not track or collect data. See
[`PRIVACY.md`](PRIVACY.md).
