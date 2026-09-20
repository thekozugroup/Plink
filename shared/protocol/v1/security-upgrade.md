# Pairing and transport security update

Both applications must be updated together and paired again. Persisted pairing records have a local `securityVersion` field: `2` identifies pairings created by the updated flow; a missing field decodes as `0`. Legacy records and keys are preserved, but live sessions must not activate them. A new replay database cannot reconstruct traffic accepted by an earlier release.

## Consent

1. The Mac creates a fresh P-256 pairing offer and nonce with a bounded lifetime.
2. Android derives a pending candidate, binds its reply listener, and sends a `preview` consent object. Neither preview nor key derivation authorizes forwarding.
3. Both apps show the same four emoji and six-digit code. The user confirms the comparison on each device.
4. Android sends an authenticated `confirmed` consent object after local confirmation.
5. After its own confirmation and verification of Android consent, the Mac sends an encrypted `pairing.confirm` event containing the matching `sessionId`, `offerNonce`, and `status: "confirmed"`.
6. Each app persists/activates trust only through its consent finalization path. Cancelled, expired, stale, and failed attempts must not activate a replacement session.

The initial consent object is JSON limited to 16 KiB with fields `version: 1`, `stage: "preview" | "confirmed"`, `confirmation`, and `proof`. `confirmation` contains the existing device identity, name, platform, endpoint, public key, target identity, offer nonce, session ID, and protocol version. `proof` is base64 HMAC-SHA256 with the derived 32-byte session key.

The HMAC input concatenates these fields in order:

```text
plink-consent-v1
stage
deviceId
deviceName
platform
endpoint
publicKey
targetDeviceId
offerNonce
sessionId
protocolVersion (decimal)
```

Each field is encoded as its decimal UTF-8 byte length, a colon, then its UTF-8 bytes. There are no separators between the resulting length-prefixed fields. This prevents ambiguous boundaries and binds consent to the endpoint and stage. The ECDH transcript uses the same length-prefix convention and includes both endpoints. Matching golden HMAC vectors and transcript tests run in Swift and Kotlin.

## Transport state

Encrypted transport framing remains a four-byte network-order length followed by one JSON frame, limited to 128 KiB. Connect, write, and incomplete-frame reads have bounded deadlines. Stopping a session closes its owned sockets and revokes callbacks.

Send sequence reservation and receive replay acceptance are persisted before a send/dispatch. State is scoped to the key fingerprint and directional device identities. A 4096-sequence receive window accepts unseen reordered frames, rejects repeated sequences/nonces, and survives process recreation. This state must remain for the lifetime of its corresponding key.

## Command outcomes

An `ack` payload includes `eventId`, `action`, and `status`. `executed` confirms Android executed the action; it does not establish that an external messaging recipient received it. `awaiting_user` means a Pixel handoff notification was posted and still needs a tap. An `error` contains the original `eventId`, a stable code, and a safe message. A successful TCP write alone is never a delivery confirmation.
