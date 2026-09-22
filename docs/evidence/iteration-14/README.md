# Iteration 14: native notification artwork and Pixel call setup

The Pixel was already bonded, connected, and HFP-capable in the Mac's public Bluetooth catalog. Plink had not saved a calling association. Live stage logs showed that the legacy `IOBluetoothDeviceSelectorController` returned failure after the app's entry checks and catalog read succeeded. The underlying macOS error is not established.

Already-paired phones now use a native AppKit chooser. The user explicitly selects a phone and confirms. The selection is bound to an immutable, address-deduplicated catalog; existing peer/session/generation checks and native bond/capability validation still run before saving. A display-name match never establishes the association.

The user confirmed that the Pixel showed Calls connected after the replacement chooser. Runtime evidence also confirmed the exact Pixel association and the native HFP connected callback. This establishes setup and connection, not successful carrier-call control or two-way audio.

Message notifications now use public macOS notification attachments for the Android source app icon, with a small circular system phone symbol. Sender, app/phone subtitle, and message remain native notification fields. macOS owns the banner layout and the left Plink attribution icon. The previously blank left icon remains unresolved until a new native screenshot proves otherwise.

Artwork is bounded before decoding, restricted to a single static PNG no larger than 96×96, and staged with bounded, per-submission ownership. Invalid artwork falls back to text; a failed decorated submission receives one generation-guarded plain retry. Reply routing remains authenticated and independent of artwork. Call-panel deduplication remains in place.

## Verification

- Initial full gate: 207 Android tests and 282 Swift tests passed, including Android lint/builds and Mac packaging/signature checks.
- Instrumented build: 282 Swift tests and signed release packaging passed.
- Bonded-selector build: 284 Swift tests and signed release packaging passed.
- Existing Pixel Wi-Fi and clipboard connections returned after installation.
- OnePlus removal was observed in the native accessibility tree; only Pixel remained in Plink's saved-phone list.
- Pixel association and connected state were observed as described above.
- The user tested a real call and reported missing pickup controls, a large notification image, and Bluetooth audio falling back to the phone. Calling failed this live check.
- The large-image report is not yet attributable: a separate synthetic message was also present. That message was cleared before the next isolated call test. No call-classification change was made without producer metadata.
- Latest notification artwork and synthetic reply checks remain unverified.

Computer use briefly returned native accessibility state, then failed with a ScreenCaptureKit error and repeated native-pipe failures. No alternative Mac UI automation was used. No Pixel display settings were changed.

This is a bounded development checkpoint, not complete iPhone feature parity or a 100% verification claim.

## Isolated call result and menu-bar mode

The second isolated call produced owned, current HFP ringing and active callbacks. Plink's custom call panel was eligible and visible. The user rejected that custom presentation and requested a real native notification; this remains an open follow-up.

Both observed SCO-open failures returned `-536870201` (`0xe00002c7`, `kIOReturnUnsupported` in the installed IOKit SDK). Call audio did not reach the Mac. This identifies the reported framework error, not its underlying OS/driver cause or a universal hardware limitation. No audio success is claimed.

Plink is now packaged with `LSUIElement=true` and uses accessory activation. A paired launch no longer opens the dashboard. Setup still opens for an unpaired/repair-needed startup; Open Plink remains available from the menu bar. The installed app was observed with accessory activation and one running instance.

The final pre-menu-bar gate passed 207 Android and 285 Swift tests (492 total). The menu-bar change also passed 285 Swift tests and release packaging. A final startup transition guard is verified separately before checkpoint.
