# Plink Research

## Goal

Plink brings Pixel-to-macOS continuity through native apps and evidence-backed interoperability work:

- Pair Pixel and Mac on a local network with a matching emoji confirmation code.
- Mirror calls and messages to macOS as native actionable notifications.
- Reply to supported messages from the macOS notification.
- Share clipboard, files, web links, media state, and device/battery state.
- Keep privileged or sensitive access explicit, permissioned, and optional.

## Current development order — 2026-09-22

The latest user direction takes precedence over the historical feature assessments below:

1. Fix actual two-way cellular call audio through the Mac.
2. Restore phone screen sharing with a native Mac viewer.
3. Fix the primary macOS notification icon.

Contacts remain a later candidate. SMS/MMS conversation history/composition and a standalone Messages app are outside current scope. Preserve existing native notification replies and actions. Restoring screen sharing does not restore the separately deferred USB webcam feature.

## Reference: Sefirah Android

Reference repo: https://github.com/shrimqy/Sefirah-Android

Useful feature cues from Sefirah:

- Local phone-link model for Android plus desktop.
- Clipboard sharing between phone and desktop.
- Desktop notification mirroring from Android notifications.
- File sharing.
- SMS texting when SMS permissions are granted.
- Media controls and remote volume commands.
- Battery and device status.
- Screen mirroring through external scrcpy integration.
- Pairing flow with user confirmation and matching keys.
- Android permission screen for notification listener, accessibility, SMS, phone state, and related capabilities.

Useful Android implementation cues:

- `NotificationListenerService` for notification mirroring.
- Accessibility service for clipboard detection where normal clipboard callbacks are insufficient.
- Device-specific preference toggles for clipboard, messages, notifications, media, storage, call state, and call logs.
- Persistent connected-device foreground service.
- Explicit SMS permissions when implementing direct SMS.

## Platform Feasibility

This table records the initial design assessment, not verified release status. The dated investigations below and `docs/evidence/` record later findings.

| Feature | Feasible Level | Implementation Path | Boundary |
| --- | --- | --- | --- |
| Pairing | High | Local network discovery/manual connect, emoji confirmation, per-device secret | Bonjour/Nearby can be added later; MVP supports manual local pairing and socket discovery model |
| Calls on Mac | Medium-high | Android call state/notification listener sends call event, macOS shows actionable native notification | Direct cellular call audio handoff like iPhone is not public Android-to-macOS API |
| Message reply from Mac notification | Medium-high | Android notification listener captures `RemoteInput` reply actions, Mac reply action sends response event back | Direct SMS send requires SMS default role or privileged SMS permissions; notification replies work only for apps exposing reply actions |
| SMS texting | Medium | Optional SMS permission/default-role path | Play policy and user default SMS role constraints apply |
| Clipboard handoff | High | Android accessibility/manual share plus macOS pasteboard monitor | Background clipboard access is restricted on modern Android; user enablement required |
| File handoff | High | Android share sheet/doc picker and macOS file importer/exporter over local transport | Background filesystem mounting needs a separate storage service and stronger review |
| Web handoff | High | Share URL/open URL event | Safari/iCloud tab parity is private Apple ecosystem behavior |
| Battery/device state | High | Android battery broadcasts and app/device state events | Some hardware details may be unavailable without extra permissions |
| Media controls | Medium-high | Android media session events and desktop control events | App-specific media sessions may restrict control |
| Screen mirroring | Medium | Optional scrcpy/ADB path | Not native Continuity; requires external tooling and user setup |

## Android Constraints

- Notification mirroring needs user-enabled notification listener access.
- Android 15 and later can hide sensitive notification content unless the app receives special permission through ADB/app-ops or equivalent user action.
- Message replies via notification require the source app to expose a `RemoteInput` action.
- Direct SMS read/send needs SMS permissions and may require being the default SMS app for policy-compliant distribution.
- Call mirroring in the current build uses notification access. Direct call-state fallback would need `READ_PHONE_STATE` and policy review, so it is not requested now.
- Clipboard auto-sync is constrained by modern Android privacy limits; foreground, accessibility, or share-sheet paths are safer.
- Shizuku can improve privileged access in developer/power-user mode, but release behavior must not depend on it.

## macOS Constraints

- Native notifications support actions and text reply through `UserNotifications`.
- Menu bar apps need AppKit bridging for `NSStatusItem`.
- Local network messaging should use `Network.framework`.
- Notification reply actions are local app actions; Plink must forward the reply to Android and Android must execute the supported reply path.
- App Store distribution will need sandbox entitlements, local network privacy strings, notification permission UX, signing, and notarization.
- iPhone Continuity features using private Apple services, iCloud identity, Call Relay, and Messages relay cannot be cloned exactly with public APIs.

## Product Boundary

Release-ready means:

- Native Android app and native macOS app compile and pass local tests.
- Pairing, protocol, call/message notification models, reply event flow, clipboard/file/web/device/media event models are implemented and testable.
- Permission-dependent features degrade clearly when unavailable.
- Private iPhone Continuity interoperability remains unverified. Track each missing trust, signaling and media mechanism separately; do not equate a native-looking interface with system integration.

## Tether assessment — 2026-09-22

Reviewed [Tether at `779b8a4`](https://github.com/zackb/tether/tree/779b8a4d970f3aa34f105fc9a84d06f186670ec1) and the [author's discussion](https://www.reddit.com/r/foss/comments/1vtbwyu/tether_linux_iphone_continuity/). This was a source review; neither Tether nor a new Plink device experiment was run. It provides useful Bluetooth interoperability work, but the reviewed implementation does not register an Android phone as an Apple Account Continuity device.

Tether's Linux client consumes the iPhone's MAP messaging, PBAP contacts, ANCS notifications and HFP call services. Clipboard and files use a separate companion connection with custom messages and TLS identities. Its Swift companion includes a macOS target; its reviewed call controls use GTK and Linux Bluetooth services. These are distinct from Apple's native Phone UI and system device identity. See [protocol roles](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/docs/BLUETOOTH.md#L1-L15), [custom protocol](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/docs/PROTOCOL.md#L1-L23), [Swift platforms](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/apple/TetherFramework/Package.swift#L14-L17), and [call controls](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/src/gtk/calls_view.cpp#L160-L181).

| Finding | Application to Plink | Evidence still needed |
| --- | --- | --- |
| MAP reads messages and submits bMessages through the phone. | Investigate SMS/MMS history and composition through a native Swift MAP client. Keep existing Android notification actions and replies. | Pixel service discovery, message-access consent, supported message types, successful Mac OBEX transactions and delivery confirmation. No RCS, arbitrary-app messaging or Android iMessage claim. |
| PBAP retrieves phone contacts. | Potential caller names and contact selection using the paired phone's contacts service. | Separate contact permission, actual Pixel service availability and bounded retrieval. |
| Tether suppresses popups for restored ANCS entries and MAP backfill. | Add an explicit restoration flag so reconnect can refresh notifications and their actions quietly. | Cross-platform regression covering action renewal, later real updates, concurrent newer posts and removals. Source review found a replay-alert risk; no new live reproduction. |
| Bluetooth bonding, call control and audio transport are separate states. | Reuse Plink's existing audio-unavailable state in the dashboard and Calls status. Currently some connected labels ignore that state. | Regression proving known audio failure cannot display unqualified call readiness. This changes status accuracy, not audio transport. |
| Linux notifications supply app/origin hints to libnotify. | Useful presentation reference only. | No mechanism in this path fixes Plink's blank macOS primary notification icon or grants Apple's paired-iPhone identity. |

Source anchors: [MAP operations](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/src/core/src/bluetooth/map_session.cpp), [PBAP fields](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/src/core/src/bluetooth/pbap_session.cpp#L88-L102), [ANCS restoration](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/src/core/src/bluetooth/ancs/notifications.cpp#L140-L142), [MAP alert filtering](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/src/daemon/main.cpp#L227-L241), and [Linux notification hints](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/src/daemon/notification.cpp#L287-L299). Relevant Plink paths are `PlinkNotificationListenerService.refreshActionSnapshot`, `NotificationBridge`, `DashboardPresentation.callsStatus`, and `BluetoothCallController.computerAudioUnavailableReason`.

### Call audio: useful separation, no Mac fix established

The README recommends leaving audio on the iPhone, while the implementation also offers optional PipeWire audio activation. Tether delegates AT negotiation, codecs and SCO/PCM transport to Linux backends. Its `route_audio` sets `RejectSCO` and calls `Activate`; it can return success even if activation fails. Neither a successful command nor a connected call proves two-way audio. See the [actual route function](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/src/core/src/bluetooth/telephony.cpp#L216-L238) and [external audio test limits](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/docs/BLUETOOTH.md#L369-L376).

Plink's observed native Answer path reached audio transfer and received owned SCO status `0xe00002c7` (`kIOReturnUnsupported`); see [iteration 28](evidence/iteration-28/README.md). Tether does not identify the cause of that Mac failure or supply a replacement macOS transport. Linux profile/configuration changes and codec guesses do not follow from this evidence. Mac call audio remains unresolved.

### Historical candidate: MAP feasibility (now outside current scope)

The proposed roles are Mac as MAP client and Android's system Bluetooth service as MAP server. At AOSP commit `745ee92b87ed62b5a8a1bac47d5df8cad623bf59`, the server checks stored message-access permission, requests consent when unknown and cancels rejected connections. Its OBEX handler implements listing/get/push; its content layer reads SMS/MMS providers and its observer has SMS/MMS send paths. This establishes an Android implementation to investigate, not the services or behavior of the user's installed Pixel build. See [consent](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/745ee92b87ed62b5a8a1bac47d5df8cad623bf59/android/app/src/com/android/bluetooth/map/BluetoothMapService.java#906), [OBEX operations](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/745ee92b87ed62b5a8a1bac47d5df8cad623bf59/android/app/src/com/android/bluetooth/map/BluetoothMapObexServer.java), [provider access](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/745ee92b87ed62b5a8a1bac47d5df8cad623bf59/android/app/src/com/android/bluetooth/map/BluetoothMapContent.java#3672), and [SMS send](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/745ee92b87ed62b5a8a1bac47d5df8cad623bf59/android/app/src/com/android/bluetooth/map/BluetoothMapContentObserver.java#3768).

The installed macOS SDK exposes `IOBluetoothOBEXSession.withSDPServiceRecord`, `OBEXConnect`, `OBEXGet`, `OBEXPut` and `OBEXSetPath`. These are candidate client primitives, not proof of runtime MAP support. Tether delegates session/service selection to BlueZ `obexd`; its C++ adapter is not a ready-made Swift MAP transport. Its iMessage behavior depends on an actual iPhone and its messaging stack.

Next proof, in order:

1. Build an isolated Swift fixture for bounded OBEX headers, MAP application parameters, listings and bMessages. Cover malformed lengths, UTF-8, cancellation, stale callbacks and exact peer/session ownership. Keep it outside the production message path until feasibility is established.
2. Discover MAS/PBAP services on the selected paired Pixel. Record advertised channels/features and consent outcome. Attempt one bounded MAP connect/disconnect. Retain session/callback objects through completion; distinguish API return from remote response, and close the underlying transport explicitly. SDK documentation says OBEX disconnect alone need not close it.
3. After access is granted, use only designated test messages to prove bounded listing/get, denial/revocation, reconnect and any required event-report channel. Then validate one authorized self-message send and receipt. Keep content out of diagnostic logs. Message access comes from the system's Bluetooth consent flow; this proposal does not require adding privileged SMS permissions to Plink.

No new MAP/PBAP capability, restoration change or audio-status change is implemented by this research checkpoint. Existing versioned notification actions, `RemoteInput` replies and peer/session checks remain the working message path.

Tether's own code is [MIT licensed](https://github.com/zackb/tether/blob/779b8a4d970f3aa34f105fc9a84d06f186670ec1/LICENSE). Reuse must preserve applicable notices; bundled dependency and per-file terms need checking for the selected subset. No third-party code was copied in this review. Source hashes and verification scope are recorded in [iteration 30 evidence](evidence/iteration-30/verification.json).

### Implemented follow-up: known call-audio failure

Iteration 31 applies the status-accuracy finding: the dashboard, menu and Calls view consume the existing connection-scoped audio-unavailable reason. A known failure displays “Mac audio unavailable,” keeps the existing phone-audio guidance and removes the green success treatment. Pairing, reconnect and call controls retain their existing behavior. This is a presentation correction; it does not establish or repair two-way audio. See [verification and limits](evidence/iteration-31/README.md).

## MPCFW and Apple pairing research — 2026-09-22

Reviewed [MPCFW at `0587375`](https://github.com/evilsocket/mpcfw/tree/0587375364b104e9752fc28c521f2a958176a43f), committed in October 2022, and the [author's protocol explanation](https://www.evilsocket.net/2022/10/20/Reverse-Engineering-the-Apple-MultiPeer-Connectivity-Framework/). Its useful contribution is an app-level Multipeer Connectivity wire-format example. The checked-in client discovers Logic Remote's Bonjour service, exchanges peer introductions/invitations, negotiates network endpoints using custom STUN, and starts a partial Logic application session. It is not a complete cellular-media or system-device-pairing implementation. The author's observation of shared STUN behavior with FaceTime does not make this a FaceTime or Call Relay client.

The implementation sends connection data with encryption and authentication disabled. It provides no reviewed Apple Account enrollment, Android cellular PCM capture/injection, screen capture or macOS notification identity mechanism. Keep Plink's existing authenticated transport rather than replacing it with this proof of concept. No explicit license was found in the pinned tree, and no source was copied. See [service discovery](https://github.com/evilsocket/mpcfw/blob/0587375364b104e9752fc28c521f2a958176a43f/mpc/mdns/__init__.py#L63-L70), [connection flags](https://github.com/evilsocket/mpcfw/blob/0587375364b104e9752fc28c521f2a958176a43f/mpc/tcp/messages.py#L619-L628), and [partial application session](https://github.com/evilsocket/mpcfw/blob/0587375364b104e9752fc28c521f2a958176a43f/mpc/ospf/session.py#L7-L52).

### Separate the pairing mechanisms

| Mechanism | What the reviewed material establishes | Plink implication |
| --- | --- | --- |
| MPC app invitation | An application accepts a nearby peer and negotiates its data connection. | Does not enroll Android in Apple's system Continuity services. |
| Bluetooth bond/HFP | Phone and computer establish a profile connection; the phone can accept call-control commands. | Already distinct from the failing SCO audio step. A successful bond or Answer does not establish audio. |
| Apple mobile Call Relay | Same Apple Account in iCloud and FaceTime, encrypted APNs signaling and a secure peer-to-peer media link; BLE stops ringing on nearby devices. | A different media architecture from Plink's HFP path. Recreating network framing alone supplies neither Apple identity nor Android cellular audio access. |
| Rapport/Handoff research | Tools expose message exchanges and identify participating processes; BLE dissectors describe nearby advertisements. | Useful for understanding service boundaries and diagnostics, not proof that an Android endpoint can authenticate as an iPhone. |

Apple's [mobile call-relay security description](https://support.apple.com/en-in/guide/security/sec28a79bf17/web) is the primary source for the account, signaling and media distinction. This review found no justification for treating an MPC peer name, Bluetooth name or BLE advertisement as equivalent to authenticated Apple-device identity.

The more relevant general reverse-engineering references are [SEEMOO's Continuity toolkit](https://github.com/seemoo-lab/apple-continuity-tools/tree/b93207b5887c6bef8c9e0e16a442149fb3520e28) and [FuriousMAC's BLE dissector](https://github.com/furiousMAC/continuity/tree/d9fa98bddafbfa3baafc84e37a417d78a0598546). SEEMOO's [process reconnaissance](https://github.com/seemoo-lab/apple-continuity-tools/blob/b93207b5887c6bef8c9e0e16a442149fb3520e28/process_recon/README.md) suggests a useful method for correlating a controlled action with the responsible service. Its [Rapport message instrumentation](https://github.com/seemoo-lab/apple-continuity-tools/blob/b93207b5887c6bef8c9e0e16a442149fb3520e28/continuity_messages/README.md) targets Handoff/Universal Clipboard, not a turnkey Call Relay stack. Some toolkit methods require altered system protections; none was executed for this review.

### What can inform an audio replacement

Martin Vigo's [Call Relay repository](https://github.com/martinvigo/apple_call_relay_protocol/tree/ad1f451c3bd18d49af3fc4da5b25f43f43f844b4) describes iOS 8/Yosemite-era communication and manipulates packets from an existing Apple-to-Apple connection. The [author's 2017 explanation](https://www.martinvigo.com/diy-spy-program-abusing-apple-call-relay-protocol/) explicitly lists decoding, decompressing and decrypting voice among unsuccessful goals. It is useful historical protocol evidence, not a working enrolled audio endpoint or a demonstrated current-macOS implementation.

A stronger media-code reference is [OpenBubbles/rustpush at `48bcc27`](https://github.com/OpenBubbles/rustpush/tree/48bcc271b220ff219513822a99aadd8c0f469e36). Its FaceTime code uses Apple identity, APNs and QuickRelay signaling. Its [audio sender](https://github.com/OpenBubbles/rustpush/blob/48bcc271b220ff219513822a99aadd8c0f469e36/src/avconference.rs#L3766-L3797) accepts frame bytes from its caller, creates and encrypts RTP packets, and sends them through its media connection; a receiver decrypts and parses packets. That establishes real network-media implementation, not Android cellular audio access or compatibility with iPhone cellular Call Relay. The repository is SSPL-licensed with an OpenBubbles-specific exception; no implementation was copied or executed.

The candidate architecture is Android call audio over Plink's authenticated IP connection, bypassing the failing Mac SCO path. The missing primitives are both **phone call downlink extraction** and **Mac microphone injection into phone call uplink**. Public Android [call recording sources](https://developer.android.com/reference/android/media/MediaRecorder.AudioSource#VOICE_CALL) require privileged access. Routing controls or a normal microphone recorder do not supply both directions. Apple transport research does not change those Android requirements.

Before building another transport, prove those two endpoints independently. The existing isolated mode-3 experiment has only offline allocation/lifecycle tests. A proposed next test would use distinct generated signals at the intended extraction and injection endpoints, with negative controls excluding ordinary microphone loopback. Its prerequisites remain unresolved: ownership and removal of every temporary audio policy must be observable, including partial construction failures and asynchronous cleanup. Passing generated signals would still require a later designated cellular-call check; it would not establish that the Pixel carrier path uses the same audio route. This review supplies no production audio fix and does not justify another equivalent SCO retry.

The smallest next feasibility check is an owned disposable Android emulator: confirm that its image exposes the exact mode-3 APIs and passes the existing helper's unchanged identity, permission and readiness checks. Only then build the two-direction fixture. Discarding that emulator contains temporary resource leaks within the experiment; it does not demonstrate cleanup or carrier-audio access on a physical Pixel. Missing prerequisites end this candidate rather than justify weaker checks. No emulator or audio probe was launched during this review.

### Screen sharing and notification identity

[pymobiledevice3's RemoteXPC documentation](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md) describes developer-service pairing and tunnels. [pyatv's Companion protocol](https://pyatv.dev/documentation/protocols/#companion) concerns Apple TV control and related authentication. Neither reviewed path establishes an Android endpoint for Apple's [iPhone Mirroring](https://support.apple.com/en-us/120421), which requires an eligible iPhone and Apple Account setup. These two source links were read at mutable upstream revisions; pin them before implementation reuse.

For Plink, the direct screen-sharing route is its retained Android MediaProjection capture and native Swift viewer. After the audio work, restore the removed manifest, consent, feature and authenticated-session wiring. Preserve fresh capture consent, current-peer/generation checks, bounded decoding, and stop/clear behavior on revocation, lock, disconnect, peer change and viewer closure. The retained profile is a view-only JPEG preview capped at 1280×720 and two frames per second; it is not smooth interactive mirroring. A higher-rate encoded-video path requires separate implementation and validation. See Android's [MediaProjection contract](https://developer.android.com/media/grow/media-projection).

The blank left notification icon remains a separate rendering failure under Plink's submitting-app identity; its cause is unresolved. Plink submits through the [current application's notification center](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/current()). The reviewed public content API does not expose an arbitrary primary app-icon or submitting-bundle override. A source-app image attachment neither changes that owner nor fixes its blank icon. None of these protocol projects identifies the cause of Plink's existing rendering failure; do not repeat icon/cache/registration experiments without new discriminating evidence.
