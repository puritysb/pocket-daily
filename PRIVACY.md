# Pocket Daily privacy policy

Effective date: 2026-08-31

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

Pocket Daily does not read precise coordinates. On macOS, location permission is
requested because the operating system gates nearby Wi-Fi network information
behind that permission. On iOS, Wi-Fi changes use Apple's system confirmation.

## Storage, sharing, and retention

Pocket Daily does not send personal data, reading files, diagnostics, or device
activity to the developer or to third parties. Direct transfers stay on the
local Bluetooth/Wi-Fi connection selected by the user.

Connection traces and imported crash reports are stored in the app's local
Application Support container. Temporary upload files are removed after the
operation completes. The user may remove retained app data by deleting the app
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
