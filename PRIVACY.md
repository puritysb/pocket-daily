# Pocket Daily privacy policy

Effective date: 2026-09-26

Pocket Daily is an account-free, local-first companion application. It does not
include advertising, analytics, tracking SDKs, or a Pocket Daily cloud service.

## Data the app handles

- Bluetooth advertisements and local-network responses from a nearby compatible
  reader, used only to discover, pair with, and identify that reader.
- A temporary Wi-Fi network name and passphrase supplied by the paired reader,
  used only to establish the direct transfer link requested by the user.
- User-selected books, learning packs, fonts, and firmware, transferred directly
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
  stored by the app.
- Reader firmware updates, only when the user taps Update reader: the app asks
  GitHub for the latest official Pocket Daily firmware release and downloads
  that file, then sends it to the user's reader. The request carries no
  personal data or reader information; GitHub sees an ordinary download from
  the device's network address.

Pocket Daily does not read precise coordinates of the device. On macOS, location permission is
requested because the operating system gates nearby Wi-Fi network information
behind that permission. On iOS, Wi-Fi changes use Apple's system confirmation.

## Storage, sharing, and retention

Pocket Daily does not send personal data, reading files, diagnostics, calendar
events, or device activity to the developer or to third parties. Direct
transfers stay on the local Bluetooth/Wi-Fi connection selected by the user.
Weather requests carry only the chosen city's coordinates to Apple WeatherKit
and Apple's geocoder, operated by Apple under its own privacy policy. Firmware
update requests go to GitHub (github.com and its download servers) only on the
user's request, contain no personal data, and are governed by GitHub's privacy
statement. A downloaded firmware file is deleted once it has been sent or the
update is cancelled.

Connection traces and imported crash reports are stored in the app's local
Application Support container. Temporary upload files are removed after the
operation completes. Prepared files are retained locally across app restarts until
successfully sent or removed with Remove prepared files. Reader IDs and pending
firmware versions are stored locally to bind retries and installation checks to
the intended reader. The user may remove retained app data by deleting the app
and its data, and controls every diagnostic export through the system share
sheet.

## Third-party links

The About screen links to this public repository and its open-source notices.
Opening those links is a user-initiated visit governed by the destination's own
privacy practices.

## Contact

Questions or deletion requests can be filed through the public support tracker:
<https://github.com/puritysb/pocket-daily/issues>

This policy will be updated before a release that adds accounts, cloud relay,
analytics, or any new category of data collection.
