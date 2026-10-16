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

The subsequent [metadata-only emulator setup attempt](evidence/iteration-33/README.md) stopped before AVD creation: the local tool did not discover the installed API-36 image, including after a process-local SDK-path correction. A small reflection-only probe compiled, but no guest or probe ran. Factory availability, shell permissions, attribution and audio mode remain unassessed. All owned temporary setup/build files were removed; the Pixel and installed applications were untouched. This is a tooling failure, not evidence against Android call-audio feasibility.

### Screen sharing and notification identity

[pymobiledevice3's RemoteXPC documentation](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md) describes developer-service pairing and tunnels. [pyatv's Companion protocol](https://pyatv.dev/documentation/protocols/#companion) concerns Apple TV control and related authentication. Neither reviewed path establishes an Android endpoint for Apple's [iPhone Mirroring](https://support.apple.com/en-us/120421), which requires an eligible iPhone and Apple Account setup. These two source links were read at mutable upstream revisions; pin them before implementation reuse.

For Plink, the direct screen-sharing route is its retained Android MediaProjection capture and native Swift viewer. After the audio work, restore the removed manifest, consent, feature and authenticated-session wiring. Preserve fresh capture consent, current-peer/generation checks, bounded decoding, and stop/clear behavior on revocation, lock, disconnect, peer change and viewer closure. The retained profile is a view-only JPEG preview capped at 1280×720 and two frames per second; it is not smooth interactive mirroring. A higher-rate encoded-video path requires separate implementation and validation. See Android's [MediaProjection contract](https://developer.android.com/media/grow/media-projection).

The blank left notification icon remains a separate rendering failure under Plink's submitting-app identity; its cause is unresolved. Plink submits through the [current application's notification center](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/current()). The reviewed public content API does not expose an arbitrary primary app-icon or submitting-bundle override. A source-app image attachment neither changes that owner nor fixes its blank icon. None of these protocol projects identifies the cause of Plink's existing rendering failure; do not repeat icon/cache/registration experiments without new discriminating evidence.

## Android Continue On assessment — 2026-10-16

The Pixel's newly visible Continue activity setting is relevant to Plink's continuity goals, but does not establish Mac compatibility. Google's [Continue On overview](https://developer.android.com/develop/better-together/continue-on) describes Android 17/API 37, Android sending and receiving devices, and initial phone-to-tablet transitions. Its [test setup](https://developer.android.com/develop/better-together/continue-on/setup) specifically names **Cross-device services > Continue activity > Tasks**, matching the reported setting, and tests with a Pixel phone and tablet using the same Google Account. The setup page still describes beta enrollment; treat it as documented test guidance rather than evidence of the Pixel's installed version or current rollout. The general [cross-device services settings](https://support.google.com/android/answer/14997291) are broader than this API: a settings entry alone does not establish which framework version, receiving devices, or third-party integrations are enabled. This assessment did not query or change the Pixel.

### What the app API provides

An app opts in each meaningful activity with `setHandoffEnabled` and supplies `HandoffActivityData` through `onHandoffActivityDataRequested`. That data identifies an Android component and portable resume state, a web destination, or a web fallback. An editor could preserve a document location; an app could offer its corresponding web page. It is an app's own cooperative export, not a public feed of every other app's state. The system may request data when an activity stops, so the callback must not cause a Mac browser to open or transmit a Plink event as a side effect. See the [enablement guide](https://developer.android.com/develop/better-together/continue-on/enable-support) and [API reference](https://developer.android.com/reference/android/app/HandoffActivityData).

A fallback URL determines what a supported receiving device opens. It does not enroll a Mac as a receiver. The reviewed guide documents no Swift/macOS receiving SDK or supported way for Plink to subscribe to other apps' handoff data. This is a boundary of the documented app API, not proof that the underlying system protocol cannot be investigated. The separate [Cross device SDK](https://developer.android.com/guide/topics/connectivity/cross-device-sdk/overview) still documents an Android-phone/tablet Developer Preview and says it must not be used in production; its non-Android roadmap does not establish a shipping Mac receiver.

### The deeper companion transport is worth investigating

There is a concrete system integration path beyond the per-activity provider API. API 37 adds public [`CompanionDeviceManager.FLAG_TASK_CONTINUITY`](https://developer.android.com/reference/android/companion/CompanionDeviceManager#FLAG_TASK_CONTINUITY), value `2`, for task-list synchronization and handoff. It is off by default and enabled for an owned companion association through `enableSystemDataSyncForTypes`. In the inspected Android 17 source, the [sync permission map](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/services/companion/java/com/android/server/companion/utils/PermissionsUtils.java#188) maps this flag to no additional permission. This does not waive association ownership, transport authentication, platform feature flags, or privileged consumer API checks.

The public `attachSystemDataTransport(int, InputStream, OutputStream)` can connect an app-supplied channel to the system's companion data protocol. Its `DELIVER_COMPANION_MESSAGES` permission is [normal](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/core/res/AndroidManifest.xml#7255), and the association must belong to the caller. However, the inspected [Android 17 attachment implementation](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/services/companion/java/com/android/server/companion/transport/CompanionTransportManager.java#227) passes a null pre-shared key, has a TODO for a PSK API, and selects secure transport with attestation for normal production use. A separate PSK path anticipates non-Android peers, but this public attachment entry point does not expose it. Plink's authenticated connection alone does not satisfy that separate authentication protocol. A native Mac receiver would also need to implement the [task-continuity wire messages](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/services/companion/java/com/android/server/companion/datatransfer/continuity/messages/). Do not use development-only insecure transport settings as evidence of a production solution.

The receiving-side [`TaskContinuityManager`](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/core/java/android/companion/datatransfer/continuity/TaskContinuityManager.java#37) is a hidden `@SystemApi`. Its remote-task listener and handoff request require `READ_REMOTE_TASKS` and `REQUEST_TASK_HANDOFF`, both [signature-or-privileged permissions](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/core/res/AndroidManifest.xml#10323). `registerRemoteTaskListener(...)` observes tasks from remote devices; `requestHandoff(associationId, remoteTaskId, ...)` requests that a remote task resume on the calling device, the Pixel here. Neither inspected method exports this Pixel's local handoff data to Plink. AOSP's [Shell manifest](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/packages/Shell/AndroidManifest.xml#382) requests those permissions, plus the handoff-settings permissions. That gives a specific Shizuku/shell feasibility question on the Pixel; it does not establish the installed build's grants, access to arbitrary local app resume data, or Mac interoperability. Shell access alone does not bypass transport authentication. These source findings are pinned to Android 17 commit `94b4c163b7dfe5ce3607f7bb8456f9573f7de57d`, rather than inferred from the lagging AOSP main branch.

Companion association also has an independent, nearer-term use: [`requestNotificationAccess(ComponentName)`](https://developer.android.com/reference/android/companion/CompanionDeviceManager#requestNotificationAccess(android.content.ComponentName)) requests user-approved access for Plink's own notification listener; sideloaded apps must first allow restricted settings where required. Presence observation can support reconnect/service lifecycle, but depends on the chosen association and presence mechanism; association alone does not guarantee Mac detection or reconnection. The implementation below complements the existing notification/action transport; it does not replace it or silently grant access.

### Existing Plink paths and useful next steps

| Goal | Existing implementation | Proposed direction |
|---|---|---|
| Continue a page on Mac | Android `ShareHandoffActivity.sendSharedText` classifies shared text into `WebOpenEvent` or `ClipboardUpdatedEvent`; Swift `HandoffPlanner` validates and opens the URL through the existing paired session. | Build on this explicit share flow. Offer a clear Continue on Mac action for a shared resumable URL. Preserve document IDs and positions only when the source app actually provides them. Receiving browser/app authentication remains necessary. |
| Return a link to the phone | `HandoffNotificationPublisher` offers an Android notification and explicit action for incoming Mac links/text. | Keep this user action and the existing opt-out controls. Add richer resume state only with a concrete source/receiver contract; do not infer private app state from screen contents or notification text. |
| Notification and reply sync | `PlinkNotificationListenerService`, notification-action/reply registries, and Swift `NotificationBridge` already use the authenticated session. Listener rebind, active snapshots and generation checks are present. | Continue improving this path directly. Continue On supplies no notification replication, reply, or dismissal contract. Investigate companion association separately for system-supported permission and presence handling. |
| Android-to-Android Plink resume | Plink currently compiles and targets SDK 36; its dashboard mainly manages pairing and settings. | Add the API 37 provider only when Plink has a useful resumable activity and an applicable receiver test. Compile against API 37 and guard older runtimes; do not mark the empty dashboard handoff-ready. |

Recommended implementation order: first evaluate companion association and notification-access/presence handling against the current pairing flow; independently make a bounded Pixel capability/permission check and native Mac transport-authentication experiment for task continuity; then implement a task receiver only if that experiment succeeds. Keep the existing explicit URL/document flow available throughout. Do not change SDK targets, add an empty Continue On integration, or replace working transports merely because the setting is visible.

The missing Mac notification icon and cellular audio failure remain separate issues. None of the reviewed Continue On APIs changes macOS notification ownership or provides a phone-call audio route. No app code, pairing, account, permissions, or device settings changed during this assessment. A documentation review is not end-to-end feature validation.

### Companion registration implementation

Plink now offers an explicit **Set up companion device** action after encrypted pairing. The initial implementation review found that the public self-managed builder requires `REQUEST_COMPANION_SELF_MANAGED`, which is [signature-or-privileged in Android 17](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/core/res/AndroidManifest.xml). A normal Plink install cannot obtain it. The implementation therefore uses an ordinary Bluetooth association on Android 13/API 33 and newer devices with companion-device support. It requests no privileged permission, device profile, background exemption, presence service, or system-data transport. Older or unsupported devices retain the existing pairing and notification-settings flow.

After authenticated reconnection, the Mac sends a `device.companion` event with its public [IOBluetooth host-controller address](https://developer.apple.com/documentation/iobluetooth/iobluetoothhostcontroller/addressasstring()). The address is bounded and validated; an empty value means unavailable. Android accepts it only from the admitted current peer, and binds it to that saved device ID and public key. Persistence rechecks the captured session while holding its admission guard. An unavailable address preserves a previously authenticated address for the same ID and key; it cannot supply an address for initial setup or a different key. The native picker uses an exact [Bluetooth address filter](https://developer.android.com/reference/android/companion/BluetoothDeviceFilter.Builder#setAddress(java.lang.String)), with single-device matching that can include already-bonded devices. The Mac must be discoverable or already Bluetooth-paired. A display name is never an authentication credential, and the Bluetooth address never replaces Plink's cryptographic transport authentication.

Metadata is sent once per authenticated connection and has no application-level acknowledgment or retry. A rejected queue submission or failed save may require reconnection. Android reports storage or reconciliation failures as a recoverable setup error only while the originating session remains current. Cancellation still propagates, and a metadata failure does not cancel an unrelated consent attempt. A later successful delivery or refresh can clear the error; this does not prove live recovery without a matching-device check.

Consent completion rechecks the current saved pairing, metadata address and returned association address. Cancellation, peer replacement, a changed key or address, or a mismatched picker result makes the result invalid. Pairing commits and rollback share a lock with registration reconciliation, so a temporary store write cannot remove an existing valid association. Reconciliation checks the known association IDs and retries their failed cleanup. It does not sweep unknown ordinary Bluetooth associations: uncertain provenance is not permission to delete one. **Remove registration** explicitly removes the system association without changing the encrypted pairing or notification permission. Mac-side unpairing is currently local to the Mac: it does not send an authenticated unpair command to Android. Remove Android registration separately in that case.

The existing **Notification access** action uses the validated companion association to request access for Plink's own listener. Without an association, or when Android rejects that request, it opens normal notification-access settings. Actual permission is read again when the app resumes. This establishes a supported setup path; it does not establish automatic Mac discovery, notification delivery, Google account integration, native Mac task continuity, or a call-audio route.

A debug-only capability receiver collects SDK versions, companion feature/service availability, the public task-continuity flag, and relevant app/shell permission metadata. It is enabled on Android 9/API 28 and newer, where the application can reliably identify its separate diagnostic process and skip Plink session restoration and clipboard initialization. The receiver is disabled on older devices. It does not enumerate tasks, change settings, grant permissions, attach a transport, or enable synchronization. It is excluded from release builds. A positive field or permission result is not an interoperability claim. Physical-device consent, permission and capability checks remain pending until a phone is connected.

On a connected development device with the debug build installed, collect it with an explicitly selected serial:

```sh
adb -s SERIAL shell am broadcast \
  -n app.plink.android/.debug.TaskContinuityCapabilitiesReceiver \
  -a app.plink.android.DEBUG_TASK_CONTINUITY_CAPABILITIES
```

The receiver requires Android's `DUMP` permission, so an ordinary third-party app cannot request the report. `absent`, `denied`, `unavailable_package`, and lookup errors remain separate outcomes. The next transport experiment still requires a production authentication mechanism compatible with Android's secure companion channel; do not attach the working Plink socket to that protocol until this requirement is resolved.
