# Iteration 12: slow startup status

Checkpoint `e9cf849` adds a 30-second startup watchdog and retains exclusive ownership of the restoration worker until it returns. A delayed restore now gets explanatory text. The watchdog does not cancel Security.framework work, start a second restore, change Keychain permissions, or prove the cause of the earlier delay.

The full verification script passed 455 unit tests: 207 Android and 248 Swift (54 XCTest, 70 app Swift Testing, 124 core Swift Testing). Android lint/builds and the signed Mac package also passed. The three added tests exercise worker ownership and delayed-state transitions; they are not native UI automation.

Before this checkpoint was installed, the prior Mac build eventually restored the saved connection. The Pixel was observed READY with clipboard connected and sync enabled. This is evidence of the prior runtime only. Installation of the watchdog build was deferred to the following dashboard checkpoint to avoid interrupting pairing and call preparation.

The Pixel has a saved Plink pairing but no saved Plink Bluetooth association. The OnePlus retains a separate association. A connected Bluetooth state machine alone does not establish the Mac as its peer, carrier call control, or two-way laptop audio. Those checks remain open. Source-app notification icon placement and its phone badge also remain unresolved.

No display settings changed during this checkpoint. Computer use again failed with “native pipe closed before response”; no alternative UI automation was used and no new screenshot is claimed.
