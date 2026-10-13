# Board companion artwork and text

The screen reuses `StickerSit`, `StickerWave`, `StickerPeek`, `StickerRoll`, and
`StickerRest` from the Eiscue app's asset catalog. These are existing project
artwork supplied by the project owner; this conversion makes no licensing claim
about that artwork. The original transparent PNGs remain unchanged.

From the repository root on macOS:

```sh
swift Scripts/generate-board-companion-assets.swift
swift Scripts/generate-board-companion-assets.swift --check
```

The generator uses CoreGraphics, ImageIO, and CoreText supplied by macOS. It
requires the `HelveticaNeue-Medium`, `PingFangSC-Medium`, and `Menlo-Bold` fonts.
It scales the complete source canvas to 160 × 160 pixels, composites alpha onto
sRGB `#16181C`, then quantizes to RGB565. It does not crop, redraw, or overwrite
the source artwork. Text is rendered from `CompanionStrings.json`, independently
of runtime code. Language IDs are part of the BLE protocol, so adding a language
also requires updating protocol validation and the app's language mapping.

Generated `companion_assets.[ch]` and `companion_text.[ch]` are checked in for
ESP-IDF builds, which do not require Apple frameworks or fonts. Each scanline is
compressed separately using repeat/literal PackBits packets with big-endian
RGB565 pixels. The decoder uses a caller-owned row buffer, without a full-screen
framebuffer or heap allocation. The generator verifies every compressed row and
rejects output larger than 200 KiB including row indexes.

`CompanionAssets.json` records source SHA-256 hashes, sizes, font names, and
decoded bitmap hashes. `--check` verifies that rerunning the generator produces
the checked-in data. A macOS font-renderer update can change antialiasing; review
the new previews before accepting regenerated resources.

Local previews are written to `.build/board-companion-preview/screens.png` and
`labels.png`. They are development artifacts and are not bundled in the app or
firmware. Example counters in the preview illustrate layout only; the running
firmware displays counts received from the app, not fabricated progress.
