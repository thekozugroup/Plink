# Manual Test Plan

## Android

1. Install debug build on Pixel.
2. Open Plink.
3. Confirm Google-style Material UI loads.
4. Enable notification listener.
5. Enable notifications.
6. Optional: enable phone state, SMS/default SMS role, accessibility clipboard, and Shizuku.
7. Confirm pairing screen shows emoji code `⚡ 🔑` for demo pairing.
8. Trigger simulator events and confirm generated event types match shared fixtures.

## macOS

1. Run `swift run PlinkMac` from `macos/`.
2. Confirm Plink appears in the menu bar.
3. Open pairing window.
4. Confirm emoji code matches Android.
5. Click `Simulate Call`; confirm native macOS notification appears.
6. Click `Simulate Message`; confirm native macOS notification appears with reply action.
7. Send a reply and confirm it is queued in the menu state/log.

## Cross-Device

1. Put Pixel and Mac on the same local network.
2. Start macOS app.
3. Start Android app.
4. Pair only if emoji code matches on both devices.
5. Send sample `call.ringing`, `message.received`, `clipboard.updated`, and `web.open` events.
6. Confirm unsupported permissions degrade visibly instead of failing silently.
