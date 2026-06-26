# Feature Parity

## Simple Summary

Plink can deliver the visible parts of Continuity that public APIs allow: key-confirmed pairing, Mac notifications for Pixel calls/messages, message replies through supported Android notification actions, clipboard/file/web handoff, battery/device status, and media event controls. It cannot become Apple Continuity internally because Apple does not expose those private services to Android.

## Parity Matrix

| Apple Continuity Feature | Plink Status | Public-API Implementation | Gap |
| --- | --- | --- | --- |
| iPhone call appears on Mac | Partial-high | Android call notification event is forwarded over secure local transport and becomes native macOS notification | No private cellular audio relay |
| Answer iPhone call from Mac | Limited | Event model supports action; Android cannot route cellular audio through macOS with public APIs | True call audio handoff unavailable |
| SMS/iMessage reply from Mac notification | Partial-high | macOS text reply sends `message.reply`; Android validates one-time reply token and executes notification `RemoteInput` when exposed by the source app | iMessage relay unavailable; SMS direct send requires role/policy |
| Universal Clipboard | Partial-high | Clipboard event and pasteboard adapters | Android background clipboard restrictions require permission/manual path |
| Handoff web pages | High | `web.open` event opens URL on peer | No Safari/iCloud tab state |
| AirDrop-style file handoff | Partial-high | `file.offer` event and local transfer boundary | No Apple AirDrop protocol |
| Instant Hotspot | Not planned | Documented out of scope | Carrier/network APIs unavailable |
| Sidecar/Continuity Camera | Not planned | Future external-tool path only | Private Apple stack |
| Battery/device status | High | `device.status` event | Hardware detail varies |
| Media controls | Partial-high | `media.state` and `media.command` events | App sessions may restrict control |

## Release Boundary

Release-ready Plink means the Android and macOS apps are native, buildable, tested, locally pairable, use encrypted local transport, and are honest about permission-gated behavior. Private Apple service parity is not claimed.
