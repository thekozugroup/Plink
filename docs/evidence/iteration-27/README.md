# Call audio diagnosis

The user confirmed answering through the Mac notification. Call presentation and
control work, but sound still falls back to the phone. Audio is not fixed.

The Mac now logs fixed diagnostic stages for the existing Answer and Audio on Mac
paths: admission/rejection, native Answer invocation, continuation checks, and
audio-transfer invocation/return. Native call order, guards, getter counts and
routing behavior are unchanged. Logs contain no caller information or operation
identifiers. A void API return proves invocation only; SCO callbacks and audible
two-way verification remain necessary.

Two source reviewers found no defect in the suspected reentrant completion path.
Independent review of the diagnostic patch confirmed preserved short-circuiting
and evaluation order. The fresh full gate passed 242 Android and 323 Swift tests,
lint and packaging. The signed update preserves the installed app identity and
data. The subsequent live trial reproduced the failure, as recorded below.

The separate phone-side construction probe was rebuilt unchanged from the reviewed
iteration-19 archive. Its 43 offline tests passed. It would allocate and release
stopped cellular audio endpoints without recording or transmitting audio.
However, the designated-call preflight reported idle telephony and communication
audio mode. The helper was **never invoked**; its staged phone file was removed.
The user subsequently confirmed that the receiving app was Phone. Those readings
therefore leave call classification unresolved; they do not establish that the
user called the wrong number or used a particular VoIP app.

No cellular endpoint allocation or audible audio success is claimed. No phone
permissions, routing, display settings, app data or pairing were changed.

## Live diagnostic trial

The user answered from the Mac and reported sound falling back to the Pixel again.
The running installed app matched the diagnostic binary. Its logs recorded HFP
ringing and an active call, but no new `calls.audio.*` stage and no SCO callback in
the captured interval. This does not establish which notification response path
handled the click. The user's subsequent screenshots showed an incoming Phone
card with three source actions and a separate active HFP card. This strongly
supports selection of the generic Android action path. It does not prove that
audio will work through HFP after correcting the notification classification.

During the active call, the current Telecom call subtree contained both `ACTIVE`
and `TelephonyConnectionService`. Telephony registry fields remained idle while
audio mode was `MODE_IN_COMMUNICATION`. Mode alone therefore must not be used to
declare that this was an app VoIP call. [AOSP telephony code](https://android.googlesource.com/platform/packages/services/Telephony/+/master/src/com/android/services/telephony/TelephonyConnection.java)
also explicitly supports communication audio mode for IMS telephony connections.

The user disabled Google Fi audio enhancement and reported the same failure. The
agent made no Fi setting change. This observation does not establish the cause.

The phone-side audio probe still has zero invocations. Its phone file, local helper
source/build copy and installer scratch/rollback archive have been removed. The
original reviewed source archive and verification evidence remain available.
