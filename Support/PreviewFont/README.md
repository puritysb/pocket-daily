# PocketSansWorld

`PocketSansWorld_12.cpfont` is Pocket Daily's automatic reading and UI family
for all 27 firmware UI languages plus Japanese, Korean, and Chinese reading
text. It is generated from pinned Noto Sans KR, JP, and SC variable fonts plus
Noto Sans and Noto Sans Hebrew. The glyphs are flattened into one `.cpfont`,
so the device does not need to switch font families while rendering
mixed-language books.

The device loads this family automatically when a book or UI string contains
CJK text. Users do not need to change the Reader Font setting. Only the glyphs
needed by the current page are paged from SD, preserving the X3 heap budget.

- Sources: Noto Sans KR and SC, Google Fonts commit
  `ec626514f79f831f1ab848a82114a0ce7e2d6372`
- Noto Sans KR SHA-256:
  `194018e6b2b293a7964f037b25c0249ce1418bc9ab3c971060a03aa57861e252`
- Noto Sans SC SHA-256:
  `a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`
- Source: Noto Sans JP, Google Fonts commit
  `295d98a7a0c17c68f1341eaeea354e7960ea70d3`
- Noto Sans JP SHA-256:
  `c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f`
- Source: Noto Sans Hebrew, CrossPoint bundled source at commit
  `94c0ba466cbb225a07f653d1c27f2a7261f1fb08`
- Noto Sans Hebrew regular SHA-256:
  `671951828bd5c95db818e5bb12dcea2d0c0dda00311888522be061ee6835125e`
- Noto Sans Hebrew bold SHA-256:
  `96f88305d31a8432f0fe6648c853cb9ef77db8e52ada8948ed0c577037d45423`
- Raster styles: Medium 500 and Bold 700 at 12 px
- License: SIL Open Font License 1.1; see `../PocketKR/OFL.txt`

Rebuild with `python scripts/build-pocket-fonts.py`.
