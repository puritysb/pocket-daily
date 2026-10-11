# Reader Wi-Fi setup

The user can enter the network name (SSID) and password in the Apple app,
without using the reader keyboard. My Reader → More → Manage Reader → Set Up Reader
Wi-Fi opens the form. First pair once through the reader's Direct connection
screen and the system passkey prompt. A paired reader must be advertising in
Direct connection or supported Bluetooth standby. When already connected on
Same Wi-Fi, supported firmware can enter Bluetooth setup from the app.

This feature never changes the Mac/iPhone Wi-Fi. It does not automatically
retrieve passwords in the background, infer a network mismatch from different IP
addresses, or repeatedly send credentials in the background. Future reader
joins use its existing saved-network selection. Personal 2.4 GHz networks,
hidden SSIDs and explicitly selected open networks are supported; enterprise
credentials and captive portals are not part of this flow.

## Transport and ownership

- Public CoreBluetooth only, using existing Bluetooth permission and bond.
  Optional Use Current Wi-Fi reads the SSID through CoreWLAN on macOS or
  NEHotspotNetwork.fetchCurrent on iOS/iPadOS. It requests location authorization
  only on tap; iOS needs Precise Location and Access Wi-Fi Information. No
  coordinates are read and no location updates are started. Denial, missing
  entitlement, no Wi-Fi, or a redacted result leaves manual entry available.
- The exclusive reader work lane suspends reading-sync BLE, heartbeat and
  other reader work while provisioning. Demo cannot send or prepare setup.
- Check authenticated BLE device ID and `WIFI1` capability before sending.
- `WIFI_JOIN <8 uppercase hex requestID> <SSID uppercase hex> <password uppercase hex or ->`.
  The entire command fits the existing 220-byte record limit. SSID: 1–32 UTF-8
  bytes, no control characters. Password: 8–63 printable ASCII characters,
  64 hexadecimal characters for a raw PSK, or explicit open-network `-`.
  Spaces and capitalization are preserved exactly; no trimming.
- Only encrypted, MITM-authenticated links may enqueue/execute this command.
  Standby requires an existing bond; ordinary short reading-sync windows reject it.
- `OK <id>` confirms a staged attempt, not connection or storage success.
  A lost acknowledgement is observed by request ID, never automatically replayed.
- Firmware tears down BLE before Wi-Fi. A bounded RTC ticket survives only an
  intentional software restart; crashes/cold boots discard it. Credentials are
  cleared at completion and not written to SD before successful association.
- On success the existing credential store saves using a temporary file and
  recoverable previous-file rename. On association failure, old credentials
  remain unchanged and the last working network is tried. Without a reachable
  old network, the reader returns to Bluetooth setup for app retry.
- HTTP status advertises `wifiSetup: 1` and optional `wifiSetupResult` with
  `requestID` and `state` (`pending`, `saved`, `failed`, `save_failed`). A matching
  reader ID and matching terminal receipt are needed before claiming success.
  An unconfirmed outcome remains explicitly unconfirmed.
- `POST /api/pocket/v1/wifi/setup?deviceID=<id>` merely opens Bluetooth setup,
  rejects credential bodies and active transfers, and does not authenticate LAN
  callers cryptographically. Credentials never travel over this HTTP endpoint.

The app does not persist or log credentials. The reader's existing SD credential
store uses obfuscation, not encryption at rest. See [privacy](../PRIVACY.md).
Firmware source of truth: [BLE contract](../../pocket-daily-firmware/docs/reading-sync-ble-v1.md).

## Verification

Swift `ReaderWiFiSetupTests` and firmware `WifiSetup` tests share exact wire
fixtures, boundary/malformed cases, identity/capability guards, lost ACK handling,
request matching, one-shot boot routing, credential erasure and demo isolation.
The developer pipeline `--wifi-setup` uses a unique nonexistent network, sends
through the actual Debug app, and requires a failed-association receipt plus
restored Same-Wi-Fi identity and inventory. No real password is read or exported.
Positive new-network association needs a user-supplied reachable test network;
no simulator or malformed-network test establishes that result.

## App Store assessment (2026-10-10)

[Review Guidelines 2.5.1 and 5.1.1](https://developer.apple.com/app-store/review/guidelines/)
permit a design using public APIs, accurate purpose strings and explicitly
requested credential handling. This implementation adds no private API,
HotspotHelper entitlement or private keychain API. Privacy policy and review
notes describe the flow. Local checks do not constitute Apple approval.

Apple's newer [Wi-Fi Infrastructure sample](https://developer.apple.com/documentation/WiFiInfrastructure/Sharing-Wi-Fi-network-credentials)
also demonstrates authorized system credential sharing with a Bluetooth
accessory on newer iOS versions. Customer use requires an EU Apple Account and
physical presence in the EU; its Accessory Transport Extension path is iOS-only,
not a universal Mac/iPad solution. It is not used in this globally available app.
See [regional conditions](https://developer.apple.com/documentation/wifiinfrastructure)
and [transport availability](https://developer.apple.com/documentation/accessorytransportextension).

For SSID lookup, [CoreWLAN](https://developer.apple.com/documentation/corewlan)
supports App Sandbox. The [iOS current-network API](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:))
requires Access Wi-Fi Information plus an authorization condition; this app uses
foreground precise-location authorization. The changed iOS capability requires
new distribution signing/export verification before upload. The user authorized
the App ID/development-profile update and physical iPhone build; that build now
succeeds with wifi-info. No App Store submission was performed.

macOS uses the public [CWKeychainFindWiFiPassword API](https://developer.apple.com/documentation/corewlan/cwkeychainfindwifipassword(_:_:_:)),
only after Use Current Wi-Fi. It queries the system keychain for the exact
currently connected SSID, checks that the SSID still matches afterward, and lets
macOS present its own authentication UI. It never changes keychain access rules.
The signed sandboxed test host returned authentication failure (-25293) with UI
suppressed, then succeeded (status 0, nonempty password) with interaction allowed.
No password or SSID was retained in diagnostic attachments. This establishes the
current Mac's behavior, not access on every Mac or App Review approval.

Autofill keeps the password only in the foreground form, never sends it without
Save and Connect, and discards late results after dismissal. Failure falls back
to manual entry. No shell keychain command, private preference-file lookup,
sandbox exception, or privileged helper is used. iOS/iPadOS retain manual password
entry; the EU-only Infrastructure path is not part of this release.

CoreBluetooth BLE accessories do not require the External Accessory/MFi path
([Apple Bluetooth](https://developer.apple.com/bluetooth/),
[MFi eligibility](https://mfi.apple.com/en/who-should-join)). Credentials remain
between the user's devices and are not accessible to the developer or partners;
this feature does not change the existing no-developer-data-collection answer
under [Apple's collection definition](https://developer.apple.com/app-store/app-privacy-details/).
