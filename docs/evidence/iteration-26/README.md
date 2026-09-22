# Current notification icon audit

The primary notification icon remains unresolved. This read-only audit found no
new cause and made no production changes or notification posts.

The installed build 5 has a valid signature, matching bundle/signing identifiers,
one LaunchServices registration for `/Applications/PlinkMac.app`, and a declared
icon resource that exists. Its ICNS and asset catalog hashes match the artwork
validated in earlier iterations. These checks do not establish which resource
Notification Center actually selects and do not prove an operating-system defect.

Independent Mac and critic reviews agreed that the evidence does not justify
another cache reset, packaging change, or speculative icon experiment.

The required fresh `./scripts/verify.sh` run passed on September 22, 2026:
242 Android tests and 323 Swift tests, plus lint and packaging. No rebuilt app was
installed. The expanded temporary Mac build bundle was unregistered and removed;
the distribution ZIP remains available.

The real-message reply reported by the user is recorded separately in
[iteration 25](../iteration-25/README.md). Call audio remains unresolved. This
checkpoint is diagnostic evidence, not product completion.
