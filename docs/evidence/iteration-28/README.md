# Iteration 28: call notification routing and retirement

The frozen changes classify structurally identified Android call notifications, revoke their generic actions, and send an existing versioned, zero-action removal before the call event. Mac regressions cover retirement while HFP owns the call, reordered updates, and held notification-add completion. Fixed Mac diagnostics distinguish native HFP and generic source-action routes. Ordinary messaging actions remain supported.

Verification passed on `final-combined-freeze.json`: the final gate exited 0 with **582 tests: 255 Android and 327 Swift** (66 XCTest, 261 Swift Testing). The isolated API 36 framework run passed all 15 groups. Baseline classifier RED and reentrant-publication RED evidence remain preserved. The earlier focused Mac run passed 23 tests, including eight retirement cases; its first invocation used the wrong toolchain and failed to find `Testing`, not because of a source defect.

Iteration 28 was **not installed on physical devices**. Pixel USB was unavailable, and computer use failed with a closed native pipe. These gates do not prove live removal of the stale source card. The generic primary notification icon also remains unresolved.

Separately, a new user-operated call on the already installed **iteration 27 diagnostic binary, PID 60479**, reached accepted native HFP Answer and requested audio transfer. At 19:19:14 UTC, the owned SCO-open callback returned **-536870201 (`0xe00002c7`)**. The local SDK's `IOReturn.h`, line 109, defines this as `kIOReturnUnsupported`. This establishes an audio-path failure after native dispatch for that call; notification routing changes alone do not fix it. No successful SCO connection or audible audio is claimed, and the underlying reason for the unsupported result remains unproven.

Cleanup completed: the owned emulator exited and owned scratch was removed. The physical phone was untouched by this iteration's verification. No private screenshots, names, numbers, or device serials are included here.

Evidence is indexed in `verification.json`. Original artifacts remain under `.a5c/artifacts/iteration28/`; the earlier gate and RED records are historical evidence, not substituted for the final gate.
