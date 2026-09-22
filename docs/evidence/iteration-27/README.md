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
data. A new live trace is still required.

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
