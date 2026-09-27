# App Store review notes

## Product identity

Pocket Daily is an independent, account-free e-book reader for iPhone, iPad and
Mac, and the companion for X3/X4 hardware that has Pocket Daily or compatible
CrossPoint-based firmware installed. Reading needs no hardware. It is not an
official Xteink or CrossPoint Reader application, does not support the
manufacturer's factory firmware or cloud service, and does not use manufacturer
logos, product photography, manuals, application assets, or firmware binaries.

References to X3, X4, CrossPoint Reader, and Xteink are limited to factual
compatibility and open-source attribution. They do not imply affiliation,
sponsorship, or endorsement.

## Review setup

The app opens on the **Library**, which already holds a short original guide,
"Welcome to Pocket Daily". Tap it to read: tap the right or left side of the
page to turn, the middle for controls (Contents, Aa text and page settings,
Library). Add more DRM-free EPUB, TXT or Markdown files with **+** (Files), or
save an article from Safari's share sheet and read it under **Articles**. On
Mac, a book opens in its own window. No account, network or hardware is needed
for reading.

**Sync** (the circular-arrows button in the Library) is optional KOReader sync.
It needs an account on a KOReader sync server; reviewers can create one from the
Sync sheet on the default public server or skip it. Reading is fully functional
without it.

The companion has an explicit, local demo mode for review without a reader:
open **Reader** (a tab on iPhone; on iPad and Mac the panel on the right of
**Customize reader**) and choose **Try demo**. **Customize reader** then
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

Firmware runs only on the external reader, never in the app. The Firmware card
checks official GitHub release metadata once per launch outside demo mode and
shows the publication date and availability against the connected reader.
Local firmware file import is not offered. The user chooses Update and confirms
the compatibility/recovery notice before download and local transfer begin.
Cancel stops the operation and cleans tracked temporary files when the reader
is reachable; failed cleanup retains a retryable copy. Already published files
are unchanged.

The app downloads `firmware.bin` only from the official repository release path,
validates size, version, ESP32-C3 structure, checksum, SHA-256 trailer when present
and Pocket Nearby Sync product identity, then stages it as `/update.bin`.
The reader validates the image again and requires its own explicit installation
confirmation. No automatic flashing follows transport completion.
Metadata requests send no reader identity or content to GitHub. A private direct
reader connection is not used for internet release checks or downloads.

## Reading and KOReader sync

The reader renders books with a bundled open-source engine (foliate-js, MIT)
inside a web view that loads only the app's own files and the open book through
a private URL scheme; scripts inside books never run and nothing is fetched from
the network. Links in a book open in the browser only after confirmation.
DRM-protected books are detected and refused.

KOReader sync is off by default. When the user signs in, the app sends the
chosen server a partial MD5 fingerprint of the book file, the position and
overall progress, the device name and a random installation ID, with the
username and an MD5 key of the password (the protocol's own scheme). Book
contents are never sent; the password is not stored and the key is kept in the
Keychain. The server is chosen by the user and operated by a third party, not
the developer; the app never moves the page to a synced position without asking.

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

## Article library development — 2026-09-27

The working tree adds Files → Add → Articles, local article retention, explicit
EPUB preparation, and an iOS/iPadOS Share → Pocket Daily extension. macOS uses
Add article to paste a link or text. HTTPS page retrieval is user initiated;
review the extracted text before saving. Link-only saves cannot be prepared
until text is added. No reader is needed to save or review articles.

The app and extension require the App Group `group.bound.serendipity.pocket.daily`.
The extension bundle ID is `bound.serendipity.pocket.daily.share`. Registering
these capabilities and obtaining matching distribution profiles are authorized
account-holder actions, still pending; unsigned local builds do not verify them.
The extension must ship with matching parent version/build and privacy manifest.
Article sending requires reader `articleLibrary: 1` plus the streaming transport.
See `docs/ARTICLES.md` (from repository root) for the contract and acceptance gates.
This is not a new Store submission or a verified physical sharing flow.
