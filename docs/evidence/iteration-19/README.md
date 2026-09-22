# Checkpoint 19: notification delivery and package publication

The isolated native AppKit notification test initially failed registration from
its temporary location. Moving the complete signed test bundle to Applications
allowed normal notification authorization. Its blue Plink icon rendered correctly
in System Settings; production Plink's existing icon remained generic.

The final test posted two owned notifications at 09:25:15 EDT on September 22.
The macOS notification daemon recorded both as delivered to alerts and
Notification Center. The five-minute observation window began after authorization.
No screenshot, extension execution, or Reply callback established their appearance
or interaction. The test removed both notifications at 09:30:15; a native query
confirmed zero owned pending/delivered requests. Its alert style was restored,
notification permission disabled, and installed test app and scratch files removed.

Computer use could operate System Settings and the test host, but selected a
calendar widget for Notification Center and failed on production Plink. No
AppleScript fallback was used. Native visual acceptance remains open.

## Packaging correction

The previous packaging script exposed the final `.app` path before metadata,
artwork, and signing were complete. A duplicate workspace registration contained
stale icon and signing metadata. This establishes inconsistent registration;
it does not establish the cause of the persistent blank notification icon.

Packaging now assembles and verifies a hidden staging bundle before publishing
the final app. Failed publication restores the previous app; once the final zip
rename succeeds, interruption preserves the coherent new app/archive pair.
Publication is not atomic across both outputs.

Eight controlled regression checks passed, including failures during signing,
verification, archiving, app publication and zip publication, plus TERM immediately
after the zip rename with and without previous outputs. A real release package
also passed strict signature verification. Run the regression with:

```sh
python3 scripts/test-package-macos.py
```

The installed production app was not replaced. The required full gate passed again:
299 Swift tests, 207 Android tests, Android builds/lint, and signed Mac packaging. Neither the production icon nor cellular Mac
audio is accepted as fixed.

## Call-audio capability check

The corrected isolated Android helper completed an idle metadata-only check on
the Pixel. Its real shell UID and package attribution matched; the existing
call-interception permissions and PSTN capability query passed. The helper
restored its process-local bootstrap state and exited successfully. Its device
JAR was removed, and display settings were unchanged.

Earlier failures came from the test helper's own context and bootstrap checks,
not an observed rejection of call-audio allocation. This check created no audio
endpoints and captured or played no sound. Endpoint allocation during a real
call and audible two-way Mac audio remain unverified. No production call-audio
implementation changed in this checkpoint.
