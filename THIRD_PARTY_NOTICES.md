# Third-party notices

Pocket Daily is an independent companion application. It interoperates with
compatible firmware derived from [CrossPoint Reader](https://github.com/crosspoint-reader/crosspoint-reader),
which is distributed under the MIT License and is copyright Dave Allie and its
contributors.

CrossPoint Reader and Xteink are names of their respective projects or owners.
Their use here describes compatibility only and does not imply affiliation,
sponsorship, or endorsement.

Pocket Daily does not use the Xteink logo, official product photography,
manuals, application interface assets, cloud service, or factory firmware. The
app's device-profile illustration is an original, neutral visualization of the
screen and functional button categories supported by compatible firmware.

Pocket Daily does not bundle CrossPoint Reader firmware, third-party books, or
the separately licensed Pocket Daily learning datasets in the application
binary. Firmware and learning-pack releases carry their own license and source
notices. User-selected files remain the user's responsibility.

## Reader engine

The in-app reader bundles a pinned subset of
[foliate-js](https://github.com/johnfactotum/foliate-js) (MIT License,
copyright 2022 John Factotum) and its vendored build of
[zip.js](https://github.com/gildas-lormeau/zip.js) (BSD 3-Clause License,
copyright 2023 Gildas Lormeau). The exact commit, file list and license texts
are in `Support/ReaderEngine/`; the app shows them under About → Reader engine
notices.

## Reader symbol font

`Support/ReaderFonts/PocketSymbols/PocketSymbols_12.cpfont`, offered for
installation on a connected reader, is derived from Noto Emoji 3.002, Noto
Sans Symbols 2 2.008 and Noto Sans Math 3.000, each under the SIL Open Font
License 1.1 (no Reserved Font Names). The unmodified license texts are bundled
beside it; provenance is in its `SOURCE.json` and the firmware repository's
`assets/fonts/PocketSymbols/README.md`.
