#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

while IFS= read -r -d '' fixture; do
  python3 -m json.tool "$fixture" >/dev/null
done < <(find shared/protocol/v1 -name '*.json' -type f -print0)

python3 - <<'PY'
import json
import base64
from pathlib import Path

allowed = set(json.loads(Path("shared/protocol/v1/schema.json").read_text())["properties"]["type"]["enum"])
for fixture in Path("shared/protocol/v1").glob("*.json"):
    if fixture.name == "schema.json":
        continue
    data = json.loads(fixture.read_text())
    missing = [key for key in ["version", "id", "type", "sentAt", "sourceDeviceId", "targetDeviceId", "requiresAck", "payload"] if key not in data]
    if missing:
        raise SystemExit(f"{fixture}: missing {missing}")
    if data["type"] not in allowed:
        raise SystemExit(f"{fixture}: invalid type {data['type']}")
    payload = data["payload"]
    if data["type"] == "pairing.offer":
        for key in ["endpoint", "nonce", "publicKey", "emojiCode"]:
            if key not in payload:
                raise SystemExit(f"{fixture}: pairing offer missing payload.{key}")
    if data["type"] == "message.received" and payload.get("canReply"):
        for key in ["packageName", "notificationKey", "replyToken"]:
            if key not in payload:
                raise SystemExit(f"{fixture}: replyable message missing payload.{key}")

screen_path = Path("shared/protocol/v1/screen-preview/cases.json")
screen = json.loads(screen_path.read_text())
if screen.get("schemaVersion") != 1:
    raise SystemExit(f"{screen_path}: unsupported schemaVersion")
profile = screen.get("profile", {})
expected_profile = {
    "name": "jpeg-1280-2fps-v1",
    "maxFramesPerSecond": 2,
    "minimumPullIntervalMs": 500,
    "maxLongEdge": 1280,
    "maxShortEdge": 720,
    "maxPixels": 921600,
    "maxJPEGBytes": 40960,
    "maxBase64Characters": 54616,
    "maxControlEnvelopeBytes": 2048,
    "maxScreenWireBytes": 98304,
    "envelopeLimitBytes": 65536,
    "transportLimitBytes": 131072,
}
if profile != expected_profile:
    raise SystemExit(f"{screen_path}: profile constants do not match the frozen contract")

names = set()
for case in screen.get("cases", []):
    name = case.get("name")
    if not name or name in names or not isinstance(case.get("valid"), bool):
        raise SystemExit(f"{screen_path}: invalid or duplicate case name {name!r}")
    names.add(name)
    if case["valid"]:
        envelope = case.get("envelope")
        if not isinstance(envelope, dict):
            raise SystemExit(f"{screen_path}: {name} lacks envelope")
        missing = [key for key in ["version", "id", "type", "sentAt", "sourceDeviceId", "targetDeviceId", "requiresAck", "payload"] if key not in envelope]
        if missing or envelope["type"] not in allowed or not envelope["type"].startswith("screen."):
            raise SystemExit(f"{screen_path}: {name} has invalid envelope ({missing})")
        if envelope["requiresAck"] is not False:
            raise SystemExit(f"{screen_path}: {name} requiresAck must be false")
        if envelope["type"] == "screen.frame":
            encoded = envelope["payload"].get("data", "")
            try:
                decoded = base64.b64decode(encoded, validate=True)
            except Exception as error:
                raise SystemExit(f"{screen_path}: {name} invalid Base64: {error}")
            if base64.b64encode(decoded).decode() != encoded or not (1 <= len(decoded) <= profile["maxJPEGBytes"]):
                raise SystemExit(f"{screen_path}: {name} noncanonical or oversized frame")
    elif not isinstance(case.get("rawEnvelope"), str):
        raise SystemExit(f"{screen_path}: invalid case {name} lacks rawEnvelope")

for vector in screen.get("encryptedVectors", []):
    for key, expected_length in [("sessionKeyBase64", 32), ("ivBase64", 12)]:
        value = vector.get(key, "")
        try:
            decoded = base64.b64decode(value, validate=True)
        except Exception as error:
            raise SystemExit(f"{screen_path}: encrypted vector {key}: {error}")
        if len(decoded) != expected_length or base64.b64encode(decoded).decode() != value:
            raise SystemExit(f"{screen_path}: encrypted vector {key} has wrong length or alphabet")
    frame = vector.get("frame", {})
    for key in ["cipherText", "signature"]:
        try:
            base64.b64decode(frame.get(key, ""), validate=True)
        except Exception as error:
            raise SystemExit(f"{screen_path}: encrypted vector frame.{key}: {error}")

if not screen.get("stateTraces"):
    raise SystemExit(f"{screen_path}: stateTraces must not be empty")

required_cases = {
    "request", "needs consent", "started", "pull one", "baseline jpeg frame",
    "idle no new frame", "stop without stream", "stop with stream", "float v",
    "exponent index", "duplicate payload key", "unknown payload field",
    "null optional stream", "requires ack", "noncanonical request id",
    "unsupported profile", "zero index", "bad base64 padding", "dimension mismatch jpeg",
}
if not required_cases.issubset(names):
    raise SystemExit(f"{screen_path}: missing required cases {sorted(required_cases - names)}")

vector_names = {vector.get("name") for vector in screen.get("encryptedVectors", [])}
required_vectors = {
    "fixed encrypted request",
    "fixed authenticated decimal index rejection",
    "fixed duplicate payload stale then current",
    "fixed duplicate payload current then stale",
}
if not required_vectors.issubset(vector_names):
    raise SystemExit(f"{screen_path}: missing required encrypted vectors {sorted(required_vectors - vector_names)}")

decoder_names = {case.get("name") for case in screen.get("decoderInvalidCases", [])}
required_decoder_cases = {
    "truncated entropy with appended eoi",
    "trailing bytes after jpeg",
    "concatenated jpeg images",
    "non jpeg png signature",
    "progressive jpeg",
    "exif orientation six",
}
if not required_decoder_cases.issubset(decoder_names):
    raise SystemExit(f"{screen_path}: missing decoder cases {sorted(required_decoder_cases - decoder_names)}")
for case in screen.get("decoderInvalidCases", []):
    try:
        decoded = base64.b64decode(case.get("data", ""), validate=True)
    except Exception as error:
        raise SystemExit(f"{screen_path}: decoder case {case.get('name')}: {error}")
    if not decoded or base64.b64encode(decoded).decode() != case["data"]:
        raise SystemExit(f"{screen_path}: decoder case {case.get('name')} is empty or noncanonical")
PY
