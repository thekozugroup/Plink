# Lucide icon sources

Source: https://github.com/lucide-icons/lucide
Commit: `951813ce76a859d4d8b145366972cbb237147a4e`
License: ISC, with MIT terms for Feather-derived icons; see `LICENSE`.

Vendored SVGs:

- `battery-charging`
- `battery`
- `bell`
- `bell-off`
- `bluetooth`
- `circle-check`
- `clipboard-copy`
- `clock-arrow-left`
- `folder`
- `link`
- `laptop`
- `message-circle`
- `monitor-smartphone`
- `monitor-off`
- `music`
- `phone`
- `refresh-cw`
- `settings`
- `shield-check`
- `sliders-horizontal`
- `smartphone`
- `video`
- `wifi`
- `wifi-off`

`android/src/main/java/app/plink/android/ui/LucideIcons.kt` converts these
24 × 24 SVG paths to native Compose `ImageVector` paths. Android launcher and
notification artwork also derives from `link.svg`.

The Mac uses native SwiftUI paths in `LucideIcon.swift`, a template menu-bar
image, and a generated `.icns` link icon. `scripts/generate-macos-icon.sh`
rebuilds the app icon with AppKit; no SVG parser ships in either app.
