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

The app opens on **Home & Sleep**. It has an explicit, local demo mode for
review without an account or reader: open **Reader** (a tab on iPhone, the
panel on the right on iPad and Mac) and choose **Try demo**. Home & Sleep then
shows previews drawn by the reader's own layout code with a sample card and
built-in sample content, captioned as sample content; nothing in them is read
from a device. Switch between the Home and Sleep screens above the preview;
My cards open from their Home page and make QR codes on the device. Demo
settings are populated, but Apply, file transfer and applying settings are
disabled so review data can never be mistaken for a connected device. Cards a
connected reader already shows can be loaded back for review.

Live hardware actions require a compatible reader:

1. Prepare a file with Add → Choose a file… under Files before switching networks. Firmware requires
   acknowledgement and is validated before entering the offline queue.
2. For shared Wi-Fi, open File Transfer → Join a Network on the reader and
   choose Find on same Wi-Fi. This requests local-network access without BLE or
   automatic Wi-Fi switching.
3. Away, open Nearby Sync on the reader (new firmware has a transport chooser),
   choose Connect directly in the app, and confirm the Wi-Fi transition. BLE
   pairing supplies the temporary credentials. No router or internet is required.
4. Choose Send under Ready to send and keep the iPhone app open. Direct sessions defer
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
identity all validate locally. When the transfer session ends, the reader shows
its own install prompt; nothing flashes without that confirmation.

**Update reader** (Reader panel, or the note shown for older reader firmware)
runs only when the user taps it and is hidden in demo mode. The app asks the
developer's public GitHub repository for the latest official Pocket Daily
firmware release, downloads `firmware.bin` over HTTPS from that repository's
release path only, applies the same image validation, and shows the firmware
warning before sending it over the local connection. The firmware runs only on
the external reader, never in the app; the reader asks before installing it.
The app sends no personal data to GitHub. Readers with enough memory can also
check for updates themselves (Pocket Daily → Sync → Check for updates).

## Weather and calendar

Weather is Apple WeatherKit data for a city the user types (geocoded with
Apple's geocoder; the device's location is not used). The Apple Weather mark
and legal link appear next to the city. Calendar access is requested only when
the user turns on calendar events; today's event titles and times are sent to
the user's reader over the local connection and are not stored or sent
elsewhere. Both are optional, and the reader simply shows an empty panel
without them.

## Privacy

Bluetooth, local-network, and location purpose strings describe the direct
reader connection. Location is used only where the operating system requires it
to inspect or join nearby Wi-Fi; coordinates are neither read nor transmitted.
The bundled privacy manifest declares app-only UserDefaults and user-selected
file-metadata access; the app does not track or collect data. See
[`PRIVACY.md`](PRIVACY.md).
