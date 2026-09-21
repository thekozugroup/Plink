# Iteration 9 evidence

## Native notification reply

A separate local test app posted **Plink reply check**, with a RemoteInput action asking for `testword`. The [baseline](native-reply-baseline.json) recorded zero callbacks. After the user acted, the [receiver result](native-reply-result.json) recorded exactly one callback and one exact match. The user explicitly confirmed the reply came from **Mac Notification Center**. The agent did not invoke the reply receiver or inject a reply directly.

This verifies a synthetic native Mac reply through the production Plink route on the installed checkpoint 8 builds; see [binary provenance](../iteration-8/installed-builds.json). It does not establish compatibility with every messaging app, external-recipient delivery, or cellular-call audio. The native send action was user-operated and was not captured in an agent screenshot. Exact callback time was not collected.

[Cleanup](fixture-cleanup.json) confirms STOP, removal of the fixture's owned files, uninstall, and removal of its host temporary directory. Plink pairing and app data were preserved.

## Automatic recovery after phone process death

The final [physical trial](recovery-final.json) began with both apps connected and Plink's own observer having resolved the selected phone. The agent terminated only the Android app process with its own UID. The foreground service returned in 1.44 seconds. On the unchanged Mac process, the [native observer log](observer-final.log) records selected-phone removal, return, conditional dispatch, authenticated acceptance, and completed replacement admission. Completion occurred 4.364 seconds after termination; the phone reported READY at the 4.82-second observation. No manual Connect, Mac restart, phone activity launch, or network change occurred during this trial.

The protocol authenticates an unadmitted phone before retiring the Mac's existing session. Discovery alone cannot replace a healthy admission. The shared fixtures and platform tests cover exact version/context validation, replay boundaries, cancellation, deadlines, and ownership. The Mac observes only the selected peer's removal and return; missed Bonjour events can still require manual recovery. There is no claim of general reboot, Doze, or arbitrary network-failure coverage.

Earlier trials failed: the [first](process-recovery.json) remained disconnected at 121.57 seconds; the [diagnostic trial](diagnostic-recovery-trial.json) resolved a baseline but rejected the returning phone as a duplicate. The Mac compared Add callbacks by service name/type/domain and Remove callbacks by object identity, leaving a stale retained entry. Removal now uses the same scoped service tuple and cleans up the retained object; resolution callbacks retain identity checks. Regressions cover equivalent removal objects, old browsers, and late resolution callbacks. The bundle also declares `_plink._tcp` in `NSBonjourServices`; that configuration change was not isolated as the sole cause of the earlier failure.

After final recovery, a fresh fixture recorded [one callback](recovered-reply-result.json), from a [zero baseline](recovered-reply-baseline.json). The user confirmed sending it from Mac Notification Center. This verifies an ordinary native reply round trip after recovery. The user later clarified that they sent “Plink reply check,” explaining why the fixture's lowercase `testword` comparison failed. This second trial does not establish exact-text preservation; the fixture does not retain received text. The initial native reply above did match exactly. Neither trial contacted an external recipient.

## Build, cleanup, and remaining checks

The [full verification gate](verification-final.log) passed **202 Android tests and 227 Swift tests** (54 XCTest, 49 app Swift Testing, 124 core Swift Testing). Android debug/release and instrumentation APK builds passed; lint reported zero errors and 39 warnings. The signed Mac bundle packaged successfully. [Results](verification-result.json) and [installed binary hashes](installed-builds.json) identify the tested checkpoint.

[Final cleanup](cleanup-final.json) records fixture STOP, empty owned fixture files, uninstall, host temporary-directory removal, and stopped discovery/log monitors. The phone remains Dozing. No display or Shizuku settings were written during this iteration; pairing and user data were preserved.

Cellular call control and two-way laptop audio remain unverified. Current clipboard delivery while the personal profile is locked was not claimed; checkpoint 6 contains the prior unlocked two-way proof. The Mac computer-use helper repeatedly crashed after startup, so no new screenshot or native control interaction is claimed. Screen sharing/webcam remain removed. Historical acceptance-freeze drift remains documented in checkpoint 8; no overall completion score or full parity claim is made.
