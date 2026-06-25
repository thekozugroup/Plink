#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for fixture in shared/protocol/v1/*.json; do
  python3 -m json.tool "$fixture" >/dev/null
done

python3 - <<'PY'
import json
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
PY
