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
Mac, a book opens in the same app window. No account, network or hardware is needed
for reading.

**Settings** (the gear at the bottom of the sidebar, in the Library header on
iPhone, or ⌘, on Mac) holds Appearance and **Continue Reading**: iCloud
key-value storage between the user's own Apple devices (on by default, no
setup) and exchange with a connected X3/X4 reader over the local connection.
Neither needs a Pocket Daily account. Pairing a reader for Bluetooth reading sync is in
**My Reader → Device** and is hidden in demo mode. Settings opens in the current
app window, including on Mac.

The companion has an explicit, local demo mode for review without a reader:
open **My Reader → Device** and choose **Try demo**. My Reader has an overview
and four destinations: **On Reader**, **Screens**, **Reading**, and **Device**.
In demo, **On Reader** lists example files labelled as examples. **Screens** then
shows previews drawn by the reader's own layout code with a sample card and
built-in sample content, captioned as sample content; nothing in them is read
from a device. Switch between the Home and Sleep screens above the preview;
My cards and Weather & calendar open dedicated source editors from Screens,
each with one apply action; closing returns to the same Home/Sleep layout.
My cards makes QR codes locally. **Reading** shows an
illustrative book and model-specific page-button actions. Demo
settings are populated, but Apply, file transfer and applying settings are
disabled so review data can never be mistaken for a connected device. Cards a
connected reader already shows can be loaded back for review.

Live hardware actions require a compatible reader:

1. In the Library, choose **Send to Reader…** for a book or saved article. The
   current-window task sheet keeps that content selected through connection.
   Other prepared books and firmware are not included in this task.
2. For shared Wi-Fi, open File Transfer → Join a Network on the reader and
   choose Find on same Wi-Fi. This requests local-network access without BLE or
   automatic Wi-Fi switching. Afterwards the app reconnects by itself whenever
   that reader answers again at its last address on the same Wi-Fi (Settings →
   Reconnect on the same Wi-Fi); it asks only that address and never changes networks.
3. Away, open Nearby Sync on the reader (new firmware has a transport chooser),
   expand the other connection methods, choose Connect directly in the app,
   and confirm the Wi-Fi transition. BLE
   pairing supplies the temporary credentials. No router or internet is required.
4. Choose Send in the task sheet and keep the iPhone app open. Closing the sheet
   keeps the task available to reopen; it does not cancel or send another task.
   Direct sessions defer
   preview/crash requests to preserve reader memory. Pending files survive an
   interruption; resume depends on firmware capability and retained session state.
   An uncertain save is checked before resending. **On Reader** shows the device
   inventory separately from prepared transfers and their progress. On Mac,
   the same selected-book task also offers an SD card destination: choose the
   destination folder and explicitly copy. This copies the original book bytes
   and reports SD-copy results separately from wireless publication; it does
   not require selecting the source book again. Demo never opens the folder
   picker or copies files.
5. Successful direct batches release the temporary connection. New firmware also
   exits the private session. Firmware still requires reader-side confirmation;
   reconnect to verify the version for an identified reader.

The developer should attach a current end-to-end physical-reader video following
[`appstore/review/REVIEW_VIDEO_CHECKLIST.md`](appstore/review/REVIEW_VIDEO_CHECKLIST.md)
and offer review hardware if requested. No backend, login, purchase, or external
account is required.

## Firmware safety boundary

Firmware runs only on the external reader, never in the app. The Firmware card
checks official GitHub release metadata outside demo mode, once per launch and
again when a reader connects (rate-limited), and shows the publication date and
availability against the connected reader. When nothing has been published it
says so rather than reporting a connection problem.
Local firmware file import is not offered. The user chooses Update and confirms
the compatibility/recovery notice before download and local transfer begin.
Download update for later instead downloads and validates a local copy without
transferring; compatibility/recovery acknowledgement is required before the
later Send update action.
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

## Reading and continuing across devices

The reader renders books with a bundled open-source engine (foliate-js, MIT)
inside a web view that loads only the app's own files and the open book through
a private URL scheme; scripts inside books never run and nothing is fetched from
the network. Links in a book open in the browser only after confirmation.
DRM-protected books are detected and refused.

Continuing across devices shares a partial MD5 fingerprint of the book file,
the position and progress, the device name and a random installation ID,
only in the user's own iCloud key-value storage or over the local connection
to the user's reader. Book contents are never sent, and the app never moves
the page to another device's position without asking.

### Background Bluetooth (`bluetooth-central`, iOS/iPadOS)

The iOS app declares the `bluetooth-central` background mode for one purpose:
keeping reading places in step with the reader the user paired with Connect
directly. After that pairing the app keeps a single pending connection to that
one bonded reader (no scanning, no other accessories, no new pairing). When the
reader closes a book, wakes or goes to sleep it may advertise briefly when memory
allows; eligible background connections are controlled by the operating system. The app
reads the reader's reading list, sends back the places that are further along
on the iPhone or iPad, and disconnects. Only a book fingerprint, the position,
the percentage and the device name cross the encrypted link. Nothing is shown,
and no page moves until the user chooses an offered place. Turning off Settings
→ Continue Reading → X3 / X4 reader cancels the pending connection;
demo mode never connects. A physical reader is required to observe it.

## Weather and calendar

Weather is Apple WeatherKit data for a city the user types (geocoded with
Apple's geocoder; the device's location is not used). The Apple Weather mark
and legal link appear next to the city. Calendar access is requested only when
the user enables the calendar feature. All or selected calendars can be used;
the selection is stored locally, but today's event titles and times are not
stored by the app and are sent only to the user's reader over the local
connection. Editing a source stays local until explicitly applied. Both sources
are optional; an explicit apply after disabling them can clear the reader content.

## Privacy

Bluetooth, local-network, and location purpose strings describe the direct
reader connection; the Bluetooth string also covers exchanging reading places
with the paired reader (see Background Bluetooth above). Location is used only where the operating system requires it
to inspect or join nearby Wi-Fi; coordinates are neither read nor transmitted.
The bundled privacy manifest declares app-only UserDefaults and user-selected
file-metadata access; the app does not track or collect data. See
[`PRIVACY.md`](PRIVACY.md).

## Article library development — 2026-09-28

Library → Articles supports saved links/text and local RSS 2.0 / Atom 1.0 subscriptions.
Choose + → Subscriptions and paste a direct HTTPS feed URL. The latest 20 entries per
feed are collected on subscription, app activation (at most once per five minutes), or
manual refresh. There is no email account integration or scheduled background delivery.
Feed-provided full text and extracted original pages are saved for offline reading.
Extraction failures keep a link and preview; Get full text allows retry or pasted text.
Subscriptions and page requests go directly to publishers without browser cookies,
credentials, scripts, images or an extraction service. Demo mode does not fetch feeds.

Tap an offline article to read in the app; its menu offers Save for later, read/unread,
Edit article, Send to Reader… and Delete. Reading and saving are independent.
Unsubscribing retains collected articles; refresh does not restore deleted feed articles.
Content, subscriptions and these flags stay on this device. Reader preparation and
sending remain explicit and use the existing EPUB format. The iOS/iPadOS Share →
Pocket Daily extension and + → Add article remain available for manual captures.

The app and extension require the App Group `group.bound.serendipity.pocket.daily`.
The extension bundle ID is `bound.serendipity.pocket.daily.share`. Registering
these capabilities and obtaining matching distribution profiles are authorized
account-holder actions, still pending; unsigned local builds do not verify them.
The extension must ship with matching parent version/build and privacy manifest.
Article sending requires reader `articleLibrary: 1` plus the streaming transport.
See `docs/ARTICLES.md` (from repository root) for the contract and acceptance gates.
This is not a new Store submission or a verified physical sharing flow.
