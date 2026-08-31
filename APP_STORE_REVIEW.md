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

The app's content and device-profile previews are visible without an account or
reader. Hardware actions require a compatible reader:

1. Open Pocket Daily on the reader and choose Nearby Sync.
2. In the Apple app, choose Find & Connect.
3. CoreBluetooth performs discovery and system pairing.
4. The paired reader supplies a short-lived private Wi-Fi lease.
5. The app uses the Hotspot Configuration capability and Apple's confirmation
   UI to join that network, verifies `/api/status`, and enables local transfer.

The developer should attach a current end-to-end review video and offer review
hardware if requested. No backend, login, purchase, or external account is
required.

## Firmware safety boundary

The app does not download or silently install executable code. A firmware file
must be selected by the user. Before transfer, the app discloses that factory
firmware is unsupported and that custom firmware can affect device support or
warranty. The app then stages the file as `/update.bin`; installation requires a
second explicit confirmation on the reader, which validates the image again.

## Privacy

Bluetooth, local-network, and location purpose strings describe the direct
reader connection. Location is used only where the operating system requires it
to inspect or join nearby Wi-Fi; coordinates are neither read nor transmitted.
See [`PRIVACY.md`](PRIVACY.md).
