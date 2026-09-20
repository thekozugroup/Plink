# Reconnecting a paired phone

Plink can prove a fresh local connection to an already paired phone after its address changes. Both apps must retain the same trusted pairing. A saved address is a discovery hint; it does not grant access to messages, replies, files or screen preview.

## Using reconnect

1. Put the Mac and phone on the same local Wi-Fi network and open Plink on both devices. On Android, background connection is optional and requires its displayed permissions.
2. On the Mac, select **Reconnect**. Plink discovers the paired phone and checks the connection in both directions.
3. If discovery fails, enter the numeric IPv4 address shown by Plink on the phone in **Phone address**, then select **Use Address**. Enter an address such as `192.168.1.20`, without a URL or port.
4. Wait for the connection result. **Cancel** stops an attempt and waits for its owned work to finish before another attempt can start.

Starting an attempt suspends the prior connection. Features become available only after the fresh proof succeeds. After an app restart, a remembered pairing starts with ordinary traffic closed; the Mac can try one eligible saved address automatically. A failed automatic attempt requires **Reconnect** or **Use Address**.

The proof allows up to four candidates within one 30-second Mac attempt. Each candidate has at most eight seconds, and the phone has a ten-second responder deadline. Cleanup must finish before an attempt can be replaced. A storage operation that is already running may delay cleanup; expired attempts cannot publish a connection.

## Supported local networks

Production reconnect accepts numeric private or link-local IPv4 addresses on an eligible connected local interface. It excludes public addresses, hostnames, VPN/point-to-point routes, the device's own address, and network/broadcast addresses. Android must expose a matching public `Network` so Plink can bind its sockets to that network.

Joining a phone hotspot remains a manual system operation. Some Android hotspot interfaces do not expose a usable public `Network`; reconnect reports that network as unavailable. This implementation does not establish Internet access or provide automatic Instant Hotspot activation. Physical hotspot behavior remains unverified.

## Security and lifecycle

The eight authenticated `reconnect.*` messages use the existing encrypted envelope, session key and durable replay counters. Fresh random challenges bind both connections, device identities and endpoint tuples. Reconnect does not exchange or replace pairing keys.

Each pair has one serialized transmit gate covering sequence reservation, sealing and completion of the owned write. A canceled or failed write consumes its reserved sequence. Every ordinary socket carries the exact connection generation that admitted it, so a later proof cannot revive an old socket.

Replacing a connection closes ordinary admission and joins its reply routes, file work, screen work and sender. The reconnect listener remains separate from ordinary admission. Newly accepted control traffic cannot make a restored pairing ready by itself.

Verified endpoint hints are stored separately from pairing records and protected with a session-derived HMAC. A staged hint is renamed only under the same live attempt authority used by cancellation and connection publication. Hint storage is not proof of a currently usable connection. If the final `done` message is lost, the two devices can temporarily report different states and require another proof; the exchange does not claim atomic agreement across both devices.

## Verification scope

The shared fixtures cover strict plaintext parsing, encrypted decoding, network policy and endpoint-store authentication. Unit tests also exercise cancellation, deadlines and generation ownership. The isolated emulator harness uses loopback forwarding to test the encrypted protocol and durable test state; it does not prove physical subnet routing, Android network binding, mDNS discovery or hotspot Internet access.

The [iteration 5 evidence](evidence/iteration-5/README.md) records passing canonical builds and the three-phase loopback reconnect run. The original physical-device and native Mac acceptance requirements remain open.
