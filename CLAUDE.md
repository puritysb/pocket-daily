# Pocket Daily Project Constitution

This document defines stable product and engineering constraints for any agent
working on Pocket Daily. Operational commands and repository hygiene belong in
`AGENTS.md`. Current, changeable state belongs in `docs/PROJECT_MEMORY.md`.

## Product identity

Pocket Daily is one universal App Store product with iOS, iPadOS, and macOS
targets. It is an account-free companion for X3/X4 readers running Pocket Daily
or compatible CrossPoint-based firmware.

The app is independent and is not affiliated with or endorsed by CrossPoint
Reader, Xteink, or a device manufacturer. Compatibility language must remain
precise. Do not imply that the app works with factory firmware or a
manufacturer cloud service.

## Core experience

- Current-network discovery never changes the Apple device Wi-Fi. Bluetooth
  pairing and a temporary private Wi-Fi lease provide an explicitly selected
  direct connection that works without a router or internet.
- Compare the HTTP device ID with the paired identity when both are available.
  Legacy status responses lack a unique ID; do not claim cryptographic LAN
  authentication or automatic installation confirmation for unidentified readers.
- Transfers publish files atomically and expose useful progress and errors.
- macOS can also copy supported files atomically to a user-selected mounted SD
  card directory.
- Demo mode supports first-run exploration and App Review without a reader, but
  it must not mutate a device, join a network, or perform a transfer.
- Pocket Hub, AgentDeck, accounts, analytics, and infrastructure Wi-Fi are not
  prerequisites for the app.

Shared behavior belongs under `Sources/` unless a platform constraint requires
a focused iOS or macOS implementation. Maintain a single coherent product
rather than treating the platforms as unrelated apps.

## App and firmware boundary

The app repository owns Apple-platform UI, discovery and transfer clients,
local persistence, Xcode configuration, and App Store assets. The sibling
`pocket-daily-firmware` repository owns reader behavior, device endpoints,
on-device validation, and flashing.

Bluetooth records, endpoint payloads, paths, and update rules are contracts
between the two repositories. A change is not complete until compatibility is
checked on both sides and the affected contract is documented or tested.

## Privacy and security

- Keep the app account-free and local-first.
- Do not add analytics, advertising SDKs, third-party tracking, or a cloud
  backend without an explicit product decision and corresponding privacy and
  App Store updates.
- Request Bluetooth, local-network, hotspot, location, and file permissions only
  when the related feature needs them, and explain their purpose accurately.
- macOS uses location only because nearby Wi-Fi discovery is platform-gated;
  Pocket Daily does not need or retain coordinates.
- Do not log secrets, passkeys, file contents, or unnecessary device-identifying
  data. Exported diagnostics must remain user initiated.
- Never store signing identities, certificates, provisioning profiles, API keys,
  or App Store Connect credentials in this repository.

## Firmware safety

Staging a firmware file is not installation. Validate supported firmware before
publication, explain compatibility and recovery implications, require explicit
acknowledgement, and preserve the reader's second confirmation before flashing.
Never introduce automatic flashing after transport completion.

## Build-system source of truth

`project.yml` is authoritative. `Pocket.xcodeproj` is generated with XcodeGen
and checked in for convenience. Never make a lasting configuration change only
inside the generated project file.

The normal macOS App Store target remains sandboxed. The separate Developer ID
entitlements are only for explicit local hardware testing and must not replace
the App Store entitlements.

## App Store integrity

`project.yml`, `appstore/submission.json`, `appstore/README.md`,
`APP_STORE_REVIEW.md`, `PRIVACY.md`, and the checked-in screenshots/assets are
the release sources of truth. Metadata and review notes must describe behavior
that exists in the submitted binary. Screenshots must show real app UI.

Use manual release unless the release plan explicitly changes. Account-holder
actions—agreements, tax/banking, certificates, identifiers, App Store Connect
records, uploads, TestFlight review, submission, and release—require authorized
access and direct evidence. Never report those actions as complete based only
on local files or validation.

## Quality bar

Keep parsing and validation deterministic and covered by tests. Fail safely on
malformed or incompatible device data. User-visible failures should explain
what happened and offer a recovery step. Hardware-dependent claims must be
distinguished from simulator or local build results.

When behavior, privacy, compatibility, or release assumptions change, update
the relevant source-of-truth document in the same change.

