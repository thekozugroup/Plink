# Known call-audio failure status

Tether's separation of call control and audio prompted a source audit of Plink's connected labels. The controller already reported an unsupported Mac audio connection, but the dashboard and Calls view could still show green “Calls connected.”

The dashboard, menu and Calls view now use that existing reason consistently. Known failure shows “Mac audio unavailable” with phone-audio guidance and no connected-success styling. A blocked connection keeps restart guidance; a disconnected connection ignores an old audio reason. No controller state, transport, pairing action or call-control behavior changed.

The focused Swift regression covers failure, normal connected state, stale disconnected state and blocked precedence. The complete build/test result and frozen source hashes are in [verification.json](verification.json). Independent source reviews checked the production wiring and unchanged controls.

This checkpoint does not repair Bluetooth audio, change the notification icon, implement MAP, or establish native visual/device verification. Builds were not installed or launched. Phone and Mac settings were untouched.
