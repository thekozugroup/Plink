# Checkpoint 15: native call notifications and audio failure handling

The user rejected the custom call popup and reported that audio stayed on the
Pixel. Calls now use `UNUserNotificationCenter`: Answer and Decline while
ringing, and End Call while active. Call notifications have no image attachment.
The custom panel is no longer presented automatically. Notification Center owns
the layout and action presentation; this does not reproduce Apple's Phone call
panel or its waveform.

Actions require the current phone, call identity, eligible session and Bluetooth
service. Old, dismissed or already-used controls cannot act on a replacement
call. Lock, sleep, phone changes and termination invalidate presentations,
including late notification delivery. Informational calls received over the
authenticated Wi-Fi session remain independent of Bluetooth failure.

## Audio findings

The preceding live Pixel call produced two SCO-open failures with
`kIOReturnUnsupported` (`0xe00002c7`), and the user heard audio only on the phone.
That is a failed audio test, not merely missing verification.

Plink now remembers this failure for the current Bluetooth connection. It keeps
answer/decline/end controls separate from audio availability and does not repeat
the known-failed Mac audio request. A new connection or a genuine successful
SCO-open callback clears the failure. Answer still requires an observed active
call; an audio callback cannot confirm that the call was answered.

Read-only inspection of the installed arm64e IOBluetooth framework, UUID
`644E0897-5ADA-3071-80EC-C93F1774D35F`, found:

- `transferAudioToComputer` directly branches to `connectSCO`. Calling the latter
  is not a different audio implementation on this installation.
- `connectSCO` constructs the observed unsupported error in both examined codec
  branches when its internal hands-free state is 2.
- The exact runtime branch was not sampled. `isConnected` accepts internal
  states 2 and 3, so its Boolean result does not establish which branch ran.
- The Mac advertises HFP and SCO support. These findings do not establish that
  its hardware cannot support call audio, or that all macOS versions fail.
- The old `IOBluetoothAddSCOAudioDevice` API is documented in the installed SDK
  as a no-op since macOS 10.9. It is not a repair for this failure.

No working alternative audio path was demonstrated. Replacing one equivalent
method with another or repeatedly asking the user to call would not establish a
fix. Two-way Mac call audio remains unresolved.

## Apple's call interface

The installed SDK marks the relevant CallKit provider and LiveCommunicationKit
APIs unavailable for native macOS. CallKit is available to Mac Catalyst, which
would require a separate target. Apple's [CXProvider documentation](https://developer.apple.com/documentation/callkit/cxprovider)
describes system VoIP presentation; it does not establish a public bridge from
Plink's AppKit app to the iPhone Continuity call panel. No Catalyst runtime
prototype was tested. That route remains research, and it would not itself
replace the failed Bluetooth audio transport.

## Verification limits

The full gate passed 207 Android tests, Android builds/lint, 301 Swift tests and
the Mac release package before the final delayed-delivery correction. After
that correction, 303 Swift tests passed and the release package was rebuilt and
its signature verified. One intervening Swift run timed out in the existing
`foundationSecureServerRejectsWrongDeviceId` network test. Its focused rerun and
the complete Swift rerun passed; the timeout's cause was not established.

The final package was installed after verifying idle phone telephony, normal
audio mode and an empty current-call list. One running Plink instance reported
accessory activation policy, which keeps the app out of the Dock.

Computer use initially failed with `Sky Computer Use native pipe closed before
response`, then recovered after installation. The real window showed a saved
connection restoration delay. A process sample traced the wait to
`KeychainPairingSecretStore.load` / `SecItemCopyMatching`, and SecurityAgent was
running. Computer use refuses access to that system app. The user was asked to
approve Plink's Keychain prompt manually; restored connection is not claimed
from this observation. This local package is ad-hoc signed.

No live native-action success is claimed. No new real call was requested, no
private Apple entitlements were used, and no Pixel display setting was changed.
The temporary Android notification fixture is absent from the Pixel; its owned
Mac build directory and temporary signing key were removed.
