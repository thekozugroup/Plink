# Feature Parity

## Simple Summary

Plink’s current build has the security, protocol, local discovery, native notification, and storage foundations for Pixel-to-Mac continuity. Live end-to-end parity still depends on permission-gated device testing and signed distribution. It cannot become Apple Continuity internally because Apple does not expose those private services to Android.

## Parity Matrix

| Apple Continuity Feature | Plink Status | Public-API Implementation | Gap |
| --- | --- | --- | --- |
| Local device pairing | Partial | macOS Bonjour advertises `_plink._tcp.` offers; Android NSD scan imports nearby Mac offers; both sides require matching emoji/numeric confirmation | Same-network hardware discovery pass still required |
| iPhone call appears on Mac | Foundation built | Android notification mapper, secure transport, and macOS notification presenter exist | Permission-gated notification device proof still required |
| Answer iPhone call from Mac | Limited | Event model supports action; Android cannot route cellular audio through macOS with public APIs | True call audio handoff unavailable |
| SMS/iMessage reply from Mac notification | Foundation built | macOS text reply sends `message.reply`; Android has one-time route validation and `RemoteInput` executor | Android inbound reply receiver and device proof still required; iMessage relay unavailable |
| Universal Clipboard | Partial | Clipboard event and macOS pasteboard adapter | Android collector is permission-gated and not release-proven |
| Handoff web pages | Partial | `web.open` event and URL validation exist | Live Android collector and device proof still required |
| AirDrop-style file handoff | Model only | `file.offer` event boundary exists | File transfer implementation still required; no Apple AirDrop protocol |
| Instant Hotspot | Not planned | Documented out of scope | Carrier/network APIs unavailable |
| Sidecar/Continuity Camera | Not planned | Future external-tool path only | Private Apple stack |
| Battery/device status | Model only | `device.status` event exists | Android collectors and macOS display handling still required |
| Media controls | Model only | `media.state` and `media.command` event names exist | MediaSession collectors/controllers still required |

## Release Boundary

Release-ready Plink means the Android and macOS apps are native, buildable, tested on real devices, locally pairable without demo constants, use encrypted local transport, and are honest about permission-gated behavior. Private Apple service parity is not claimed.
