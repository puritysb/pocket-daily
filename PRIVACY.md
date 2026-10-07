# Pocket Daily privacy policy

Effective date: 2026-09-27
Last updated: 2026-10-05

Pocket Daily is an account-free, local-first e-book reader and companion
application for compatible X3/X4 readers. It does not include advertising,
analytics, tracking SDKs, or a Pocket Daily cloud service.

## Your library and reading

Books you add (EPUB, and text or Markdown converted to EPUB), their covers, and
your reading position and text settings are stored only in the app's local
Application Support container. The reader engine runs inside the app, does not
run scripts from books, and does not load anything from the network. Links in a
book open in your browser only after you confirm. Removing a book deletes its
local copy; deleting the app deletes the library.

## Keeping your place across devices

- iCloud (on by default when you are signed in to iCloud): for each book you
  open, a fingerprint of the book file, your position and progress, this
  device's name and a random installation identifier are stored in your own
  iCloud key-value storage so your other Apple devices can offer to continue.
  Apple operates iCloud under its own privacy policy; the developer receives
  nothing. Turn it off in Library → Sync.
- Your X3/X4 reader (on by default): while connected over the local
  connection, the app and a reader whose firmware supports it exchange the same
  kind of record for books both have. A reader paired with Connect directly
  also exchanges them over its encrypted Bluetooth connection when it closes a
  book, wakes or goes to sleep, including while the app is in the background;
  file names are not sent. Nothing leaves the local connection.


## Data the app handles

- Bluetooth advertisements and local-network responses from a nearby compatible
  reader, used only to discover, pair with, and identify that reader.
- For the reader paired with Connect directly: the system's Bluetooth
  identifier for it and its reader ID, stored on-device so reading places can
  be exchanged with that one reader. The pairing passkey is never stored.
- A temporary Wi-Fi network name and passphrase supplied by the paired reader,
  used only to establish the direct transfer link requested by the user.
- User-selected books, learning packs, fonts, and requested firmware updates, transferred directly
  between the user's Apple device, reader, or mounted SD card.
- Device status, connection diagnostics, and crash reports from the compatible
  reader. These remain on the Apple device unless the user explicitly exports
  them with the system share sheet.
- The last successful local reader address, stored on-device to make a later
  reconnection faster.
- Weather, only if the user names a city: Pocket Daily looks up that city's
  coordinates with Apple's geocoder and requests its forecast from Apple
  WeatherKit. The city and the last forecast are stored on-device and sent to
  the user's reader. The device's own location is never used for weather.
- Calendar events, only if the user turns on calendar events: with the
  system's permission, today's event titles and times are read on-device and
  sent only to the user's reader over the local connection. They are not
  stored by the app. The choice of all or selected calendars is stored locally;
  a source change is sent to the reader only when the user applies it.
- Firmware availability: outside demo mode, the app asks GitHub for the latest
  official release metadata (version and publication date) once per app launch
  and again when a reader connects, at most once every ten minutes after an
  answer and once a minute after a failed check.
  The firmware file is downloaded only at the user's request. Confirmed Update
  downloads and sends to the connected reader; Download update for later only
  prepares a local copy, with confirmation before a later Send update.
  Requests contain no reader identity or file
  contents; GitHub receives the device's network address.


Pocket Daily does not read precise coordinates of the device. On macOS, location permission is
requested because the operating system gates nearby Wi-Fi network information
behind that permission. On iOS, Wi-Fi changes use Apple's system confirmation.

## Articles and subscriptions

When you share an article link or tap Get article text, Pocket Daily requests
the selected HTTPS page and its HTTPS redirects directly from its publisher.
The publisher sees your network address and the requested URL. The app does not
send reader information, browser cookies, or an account login, execute page scripts,
or request embedded images and other page resources. Extraction may fail on
login-protected or script-dependent pages; you can save the link or paste selected
text instead. Review manually extracted text before saving.

When you subscribe to an HTTPS RSS or Atom feed, Pocket Daily requests that feed
and attempts to save the latest 20 articles, using feed text or requests to the
original article URLs. These direct publisher requests happen when you subscribe,
open the app (at most once per five minutes), or choose Refresh. They have the same
cookie-free, script-free behaviour described above. There is no email account
connection, tracking-pixel loading, server relay or scheduled background delivery.
Subscription URLs, titles, read state and saved state stay on this device.
Unsubscribing stops future collection and keeps all previously collected articles.
Deleted feed articles leave local identity hashes so refresh does not restore them.

Article links, titles and saved text stay in a local shared container used by the
iOS share extension and the app. On macOS, they are stored in the app’s local Application Support directory.
They remain until you explicitly delete them from Articles. Sending or deleting a reader copy does not delete the app copy.
No article is sent to the developer or an extraction service.

## Storage, sharing, and retention

Pocket Daily does not send saved reading files, diagnostics, calendar events,
or device activity to the developer or to third parties. Article retrieval
sends the selected URL to its publisher, as described above. Direct
transfers stay on the local Bluetooth/Wi-Fi connection selected by the user.
Weather requests carry only the chosen city's coordinates to Apple WeatherKit
and Apple's geocoder, operated by Apple under its own privacy policy. Firmware
metadata checks go to api.github.com at launch, when a reader connects, or on explicit retry.
User-requested downloads go to github.com and its download servers. These
requests are governed by GitHub's privacy statement. A downloaded firmware file is deleted once it has been sent or the
update is cancelled.

Connection traces and imported crash reports are stored in the app's local
Application Support container. Temporary upload files are removed after the
operation completes. Prepared files are retained locally across app restarts until
successfully sent or removed with Remove prepared files. Reader IDs and pending
firmware versions are stored locally to bind retries and installation checks to
the intended reader. Book-transfer task records retain the selected book
references, destination reader and per-file results locally so an interrupted
task can be reopened and an uncertain result checked without resending it.
The user may remove retained app data by deleting the app
and its data, and controls every diagnostic export through the system share
sheet.

## Third-party links

The About screen links to this public repository and its open-source notices.
Opening those links is a user-initiated visit governed by the destination's own
privacy practices.

## Contact

Questions or deletion requests can be filed through the public support tracker:
<https://github.com/puritysb/pocket-daily/issues>

This policy will be updated before a release that adds Pocket Daily accounts,
cloud relay, analytics, or any new category of data collection.
