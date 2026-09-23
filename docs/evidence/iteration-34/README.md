# Connected Pixel preflight and native audio diagnostic

The connected Pixel exposes the Android call-audio extraction and injection methods to the shell process. Shizuku runs as shell, and Plink already has permission to use it. A reflection-only probe checked method signatures; it did not create audio endpoints, capture or inject audio, register policies, or change routing. The temporary probe was removed from both devices.

The Mac now captures one bounded diagnostic when its owned Bluetooth connection reports `kIOReturnUnsupported`. It records the loaded IOBluetooth framework UUID, up to eight image-relative stack offsets, and whether the transfer invocation is still on the stack. It records no raw addresses, symbols, call contents or phone identifiers. Existing answer, transfer and retry behavior is unchanged. This can locate the rejection but is not an audio fix.

All 589 tests passed through `./scripts/verify.sh`, including Android lint/builds and signed Mac packaging. The tested Mac executable was installed, its signature and hash verified, and Bluetooth reconnected successfully. Pairing and phone settings were preserved. The temporary installation backup was removed.

The user completed a new call and answered through the Mac native call notification. The Answer action reached the owned Bluetooth worker, but audio fell back to the phone. The matching framework UUID and image-relative return address `0x63f74` identify a synchronous unsupported callback from `connectSCO` before the transfer invocation returned. The earlier failing branch is not established. Two-way Mac call audio remains broken. Screen-sharing restoration and the primary notification icon remain unresolved. See [verification.json](verification.json) for the exact evidence and limits.
