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
import hashlib
import re
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

RECONNECT_CASES = Path("shared/protocol/v1/reconnect/cases.json")
NETWORK_CASES = Path("shared/protocol/v1/reconnect/network-cases.json")
ENCRYPTED_VECTORS = Path("shared/protocol/v1/reconnect/encrypted-vectors.json")
RECONNECT_SHA256 = "d8b47bc8281c699aa2726d3caf966e11c0acbf6be1eda73e634cea4726aefe7d"
NETWORK_SHA256 = "ff290c635c10d36fa9bc0aebd7ac2824df6b7d41f3b826c2185f5165e7d2b8cf"
ENCRYPTED_SHA256 = "3bfa3569baeda3122dc8fce2a6a4244102cff5cc165c8948e8b6c4f63682ad89"
RECONNECT_TYPES = [
    "reconnect.hello", "reconnect.challenge", "reconnect.proof", "reconnect.reverse",
    "reconnect.reverse_proof", "reconnect.ready", "reconnect.commit", "reconnect.done",
]
RECONNECT_FIELDS = ["version", "id", "sentAt", "sourceDeviceId", "targetDeviceId", "requiresAck", "type", "payload"]
UUID4 = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
TIMESTAMP = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
NONCE = re.compile(r"^[A-Za-z0-9_-]{43}$")
ENDPOINT = re.compile(r"^(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2}):45731$")

def fail(path, detail):
    raise SystemExit(f"{path}: {detail}")

def integer(value, path, detail):
    if type(value) is not int:
        fail(path, detail)
    return value

def canonical_base64(value, path, detail, length=None):
    if not isinstance(value, str):
        fail(path, detail)
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception as error:
        fail(path, f"{detail}: {error}")
    if base64.b64encode(decoded).decode() != value or (length is not None and len(decoded) != length):
        fail(path, detail)
    return decoded

def strict_json(raw, path):
    def no_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate key {key!r}")
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=no_duplicates)

def file_json(path, digest):
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != digest:
        fail(path, "frozen SHA-256 does not match")
    return json.loads(raw)

schema = json.loads(Path("shared/protocol/v1/schema.json").read_text())
schema_reconnect = [name for name in schema["properties"]["type"]["enum"] if name.startswith("reconnect.")]
if schema_reconnect != RECONNECT_TYPES:
    fail(Path("shared/protocol/v1/schema.json"), "reconnect type contract must contain exactly the approved eight types")

def check_reconnect_envelope(envelope, path):
    if not isinstance(envelope, dict) or set(envelope) != set(RECONNECT_FIELDS):
        fail(path, "reconnect envelope fields do not match the contract")
    if integer(envelope["version"], path, "version must be an integer") != 1:
        fail(path, "version must be 1")
    if not isinstance(envelope["id"], str) or not UUID4.fullmatch(envelope["id"]):
        fail(path, "id must be a canonical lowercase UUIDv4")
    if not isinstance(envelope["sentAt"], str) or not TIMESTAMP.fullmatch(envelope["sentAt"]):
        fail(path, "sentAt must be whole-second UTC Z")
    for key in ("sourceDeviceId", "targetDeviceId"):
        value = envelope[key]
        if not isinstance(value, str) or not value or len(value.encode()) > 128:
            fail(path, f"{key} must be a nonempty value of at most 128 UTF-8 bytes")
    if envelope["requiresAck"] is not False or envelope["type"] not in RECONNECT_TYPES:
        fail(path, "reconnect type or requiresAck is invalid")
    payload = envelope["payload"]
    required = {"v", "m", "mac", "phone"}
    if envelope["type"] in RECONNECT_TYPES[1:3]:
        required.add("p")
    elif envelope["type"] in RECONNECT_TYPES[3:]:
        required.update(("p", "r"))
    if not isinstance(payload, dict) or set(payload) != required:
        fail(path, "reconnect payload fields do not match the message type")
    if integer(payload["v"], path, "payload.v must be an integer") != 1:
        fail(path, "payload.v must be 1")
    for key in ("m", "p", "r"):
        if key in payload and (not isinstance(payload[key], str) or not NONCE.fullmatch(payload[key])):
            fail(path, f"payload.{key} must be a 43-character base64url nonce")
    for key in ("mac", "phone"):
        value = payload[key]
        if not isinstance(value, str) or not ENDPOINT.fullmatch(value):
            fail(path, f"payload.{key} must be a canonical IPv4:45731 endpoint")
        octets = value.split(":", 1)[0].split(".")
        if any(int(octet) > 255 for octet in octets):
            fail(path, f"payload.{key} contains an invalid IPv4 octet")

reconnect = file_json(RECONNECT_CASES, RECONNECT_SHA256)
if set(reconnect) != {"schemaVersion", "status", "contract", "cases"} or reconnect["schemaVersion"] != 1:
    fail(RECONNECT_CASES, "unexpected top-level reconnect fixture shape")
cases = reconnect.get("cases")
if not isinstance(cases, list) or len(cases) != 27:
    fail(RECONNECT_CASES, "expected exactly 27 cases")
if sum(case.get("valid") is True for case in cases) != 9 or sum(case.get("valid") is False for case in cases) != 18:
    fail(RECONNECT_CASES, "expected 9 valid and 18 invalid cases")
case_names = set()
for case in cases:
    name = case.get("name")
    if not isinstance(name, str) or not name or name in case_names or type(case.get("valid")) is not bool:
        fail(RECONNECT_CASES, f"invalid or duplicate case name {name!r}")
    case_names.add(name)
    label = f"{RECONNECT_CASES}: {name}"
    raw = case.get("rawEnvelope")
    raw_base64 = case.get("rawEnvelopeBase64")
    if raw is not None and not isinstance(raw, str):
        fail(label, "rawEnvelope must be a string")
    if raw_base64 is not None:
        raw_bytes = canonical_base64(raw_base64, label, "rawEnvelopeBase64 is not canonical Base64")
        if raw is not None:
            fail(label, "rawEnvelope and rawEnvelopeBase64 are mutually exclusive")
        replacement = case.get("replacedByte")
        if set(replacement or ()) != {"index", "originalHex", "replacementHex"}:
            fail(label, "rawEnvelopeBase64 requires replacedByte metadata")
        index = integer(replacement["index"], label, "replacedByte.index must be an integer")
        if index < 0 or index >= len(raw_bytes) or not re.fullmatch(r"[0-9a-f]{2}", replacement["originalHex"]) or not re.fullmatch(r"[0-9a-f]{2}", replacement["replacementHex"]):
            fail(label, "replacedByte metadata is out of range")
        if raw_bytes[index] != int(replacement["replacementHex"], 16):
            fail(label, "replacedByte does not describe rawEnvelopeBase64")
        try:
            raw_bytes.decode("utf-8")
        except UnicodeDecodeError:
            pass
        else:
            fail(label, "rawEnvelopeBase64 must preserve the malformed UTF-8 vector")
    if "rawEnvelopeBytes" in case:
        byte_count = integer(case["rawEnvelopeBytes"], label, "rawEnvelopeBytes must be an integer")
        if raw is None or byte_count != len(raw.encode("utf-8")):
            fail(label, "rawEnvelopeBytes does not equal rawEnvelope UTF-8 length")
    if case["valid"]:
        if "envelope" in case:
            check_reconnect_envelope(case["envelope"], label)
        elif raw is not None:
            try:
                check_reconnect_envelope(strict_json(raw, label), label)
            except (ValueError, json.JSONDecodeError) as error:
                fail(label, f"valid rawEnvelope is not strict JSON: {error}")
        else:
            fail(label, "valid case lacks envelope")
    else:
        expected = case.get("expectedRejection")
        if not (isinstance(expected, str) and expected or isinstance(expected, list) and expected and all(isinstance(x, str) and x for x in expected)):
            fail(label, "invalid case lacks expectedRejection")
        if raw is None and raw_base64 is None:
            fail(label, "invalid case lacks raw envelope data")
        if raw is not None:
            try:
                strict_json(raw, label)
            except (ValueError, json.JSONDecodeError) as error:
                if "duplicate" not in str(expected).lower():
                    fail(label, f"raw envelope cannot be parsed strictly: {error}")

network = file_json(NETWORK_CASES, NETWORK_SHA256)
if set(network) != {"schemaVersion", "status", "contract", "scope", "cases"} or network["schemaVersion"] != 1:
    fail(NETWORK_CASES, "unexpected top-level network fixture shape")
network_cases = network.get("cases")
if not isinstance(network_cases, list) or len(network_cases) != 28:
    fail(NETWORK_CASES, "expected exactly 28 cases")
network_names = set()
interface_fields = {"name", "index", "localIPv4", "prefixLength", "up", "loopback", "pointToPoint", "broadcast", "vpn", "matchingAndroidNetwork"}
for case in network_cases:
    name = case.get("name")
    if not isinstance(name, str) or not name or name in network_names:
        fail(NETWORK_CASES, f"invalid or duplicate network case {name!r}")
    network_names.add(name)
    if set(case) not in ({"name", "endpoint", "interface", "expectedMac", "expectedAndroid"}, {"name", "endpoint", "interface", "expectedMac", "expectedAndroid", "reason"}):
        fail(NETWORK_CASES, f"{name}: unexpected case fields")
    if not isinstance(case["endpoint"], str) or not isinstance(case["interface"], dict) or set(case["interface"]) != interface_fields:
        fail(NETWORK_CASES, f"{name}: invalid endpoint or interface shape")
    if type(case["expectedMac"]) is not bool or type(case["expectedAndroid"]) is not bool:
        fail(NETWORK_CASES, f"{name}: expected results must be booleans")
    interface = case["interface"]
    if not isinstance(interface["name"], str) or integer(interface["index"], NETWORK_CASES, f"{name}: interface index must be an integer") < 0:
        fail(NETWORK_CASES, f"{name}: invalid interface identity")
    if not isinstance(interface["localIPv4"], str) or not 0 <= integer(interface["prefixLength"], NETWORK_CASES, f"{name}: prefixLength must be an integer") <= 32:
        fail(NETWORK_CASES, f"{name}: invalid local prefix")
    if any(type(interface[key]) is not bool for key in interface_fields - {"name", "index", "localIPv4", "prefixLength"}):
        fail(NETWORK_CASES, f"{name}: interface flags must be booleans")
    if "reason" in case and (not isinstance(case["reason"], str) or not case["reason"]):
        fail(NETWORK_CASES, f"{name}: reason must be nonempty")

vectors = file_json(ENCRYPTED_VECTORS, ENCRYPTED_SHA256)
if set(vectors) != {"generator", "schemaVersion", "scope", "status", "vectors"} or vectors["schemaVersion"] != 1:
    fail(ENCRYPTED_VECTORS, "unexpected top-level encrypted vector shape")
vectors = vectors.get("vectors")
if not isinstance(vectors, list) or len(vectors) != 13:
    fail(ENCRYPTED_VECTORS, "expected exactly 13 encrypted vectors")
if sum(vector.get("valid") is True for vector in vectors) != 9 or sum(vector.get("valid") is False for vector in vectors) != 4:
    fail(ENCRYPTED_VECTORS, "expected 9 valid and 4 invalid encrypted vectors")
vector_names = set()
frame_fields = {"cipherText", "issuedAt", "nonce", "sequence", "signature", "sourceDeviceId", "targetDeviceId", "version"}
wire_lengths = []
for vector in vectors:
    name = vector.get("name")
    label = f"{ENCRYPTED_VECTORS}: {name}"
    if not isinstance(name, str) or not name or name in vector_names or type(vector.get("valid")) is not bool:
        fail(ENCRYPTED_VECTORS, f"invalid or duplicate vector name {name!r}")
    vector_names.add(name)
    if set(vector) not in ({"name", "valid", "sessionKeyBase64", "ivBase64", "plaintextBase64", "frame", "wire"}, {"name", "valid", "sessionKeyBase64", "ivBase64", "plaintextBase64", "frame", "wire", "wireBytes"}):
        fail(label, "unexpected vector fields")
    canonical_base64(vector["sessionKeyBase64"], label, "sessionKeyBase64 is invalid", 32)
    canonical_base64(vector["ivBase64"], label, "ivBase64 is invalid", 12)
    plaintext = canonical_base64(vector["plaintextBase64"], label, "plaintextBase64 is invalid")
    if len(plaintext) > 2048:
        fail(label, "plaintextBase64 exceeds the 2048-byte reconnect limit")
    frame = vector["frame"]
    if not isinstance(frame, dict) or set(frame) != frame_fields:
        fail(label, "invalid encrypted frame shape")
    if integer(frame["version"], label, "frame.version must be an integer") != 1 or integer(frame["sequence"], label, "frame.sequence must be an integer") < 1:
        fail(label, "invalid frame version or sequence")
    if not isinstance(frame["nonce"], str) or not UUID4.fullmatch(frame["nonce"]):
        fail(label, "frame.nonce must be a canonical lowercase UUIDv4")
    if not isinstance(frame["issuedAt"], str) or not TIMESTAMP.fullmatch(frame["issuedAt"]):
        fail(label, "frame.issuedAt must be whole-second UTC Z")
    if any(not isinstance(frame[key], str) or not frame[key] for key in ("sourceDeviceId", "targetDeviceId")):
        fail(label, "frame device IDs must be nonempty strings")
    canonical_base64(frame["cipherText"], label, "frame.cipherText is invalid")
    canonical_base64(frame["signature"], label, "frame.signature is invalid", 32)
    if not isinstance(vector["wire"], str):
        fail(label, "wire must be a string")
    try:
        parsed_wire = strict_json(vector["wire"], label)
    except (ValueError, json.JSONDecodeError) as error:
        fail(label, f"wire is not strict JSON: {error}")
    if parsed_wire != frame:
        fail(label, "wire does not encode the declared frame")
    if "wireBytes" in vector:
        wire_bytes = integer(vector["wireBytes"], label, "wireBytes must be an integer")
        if wire_bytes != len(vector["wire"].encode("utf-8")):
            fail(label, "wireBytes does not equal wire UTF-8 length")
        wire_lengths.append(wire_bytes)
if sorted(wire_lengths) != [4096, 4097]:
    fail(ENCRYPTED_VECTORS, "missing exact 4096/4097-byte encrypted wire vectors")

# Supplemental review cases preserve the original wire/network expectations.
endpoint_vectors = file_json(Path("shared/protocol/v1/reconnect/endpoint-store-vectors.json"),
    "955bee9c9882266c07f9ccee682d5a0468f7a6ff3311f10a5bbf1b662ff20ea6")
outer_path = Path("shared/protocol/v1/reconnect/outer-timestamp-vectors.json")
outer_vectors = file_json(outer_path,
    "3d52bb3664f81603fdc42b824e74517293946aa795bb89512177371cd6562b9c")["vectors"]
if len(endpoint_vectors["vectors"]) != 3 or len(outer_vectors) != 5:
    fail(outer_path, "supplemental vector inventory changed")
if sum(vector["valid"] is True for vector in outer_vectors) != 1:
    fail(outer_path, "expected one valid and four invalid outer timestamp vectors")
for vector in outer_vectors:
    if strict_json(vector["wire"], outer_path) != vector["frame"]:
        fail(outer_path, "wire does not encode declared frame")
classification_path = Path("shared/protocol/v1/reconnect/classification-cases.json")
classification = file_json(classification_path,
    "a271cc963d9fbc3bde517e7a59eba45c9e66768770a12685f0eb51af84ce3002")["cases"]
if len(classification) != 10 or sum(case["valid"] is True for case in classification) != 2:
    fail(classification_path, "expected two valid and eight invalid classification cases")
for case in classification:
    if len(case["rawEnvelope"].encode("utf-8")) != case["rawEnvelopeBytes"]:
        fail(classification_path, "classification fixture byte count differs")
PY
