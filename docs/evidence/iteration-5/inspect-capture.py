#!/usr/bin/env python3
"""Independently inspect completed synthetic captures; optionally remove raw bytes."""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import struct


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate outer field")
        result[key] = value
    return result


def inspect(directory):
    summary = json.loads((directory / "summary.json").read_text())
    assert summary["passed"] is True and not summary["errors"]
    results = {}
    for direction, source, target in [
        ("android-to-mac", "test-pixel", "test-mac"),
        ("mac-to-android", "test-mac", "test-pixel"),
    ]:
        raw = (directory / (direction + ".bin")).read_bytes()
        offset, largest, previous = 0, 0, 0
        nonces, sequences = set(), []
        while offset < len(raw):
            assert offset + 4 <= len(raw)
            size = struct.unpack_from("!I", raw, offset)[0]
            offset += 4
            assert 0 < size <= 131_072 and offset + size <= len(raw)
            frame = json.loads(raw[offset:offset + size], object_pairs_hook=unique_object)
            offset += size
            assert set(frame) == {
                "version", "sequence", "nonce", "issuedAt", "sourceDeviceId",
                "targetDeviceId", "cipherText", "signature",
            }
            assert type(frame["version"]) is int and frame["version"] == 1
            sequence = frame["sequence"]
            assert type(sequence) is int and sequence > previous
            assert isinstance(frame["nonce"], str) and frame["nonce"] not in nonces
            assert frame["sourceDeviceId"] == source and frame["targetDeviceId"] == target
            assert len(base64.b64decode(frame["cipherText"], validate=True)) >= 28
            assert len(base64.b64decode(frame["signature"], validate=True)) == 32
            nonces.add(frame["nonce"])
            sequences.append(sequence)
            previous = sequence
            largest = max(largest, size)
        assert sequences
        digest = hashlib.sha256(raw).hexdigest()
        recorded = summary["directions"][direction]
        assert (len(sequences), len(raw), largest, digest) == (
            recorded["frames"], recorded["wireBytes"], recorded["maximumFrameBytes"], recorded["captureSha256"]
        )
        results[direction] = {
            "frames": len(sequences), "wireBytes": len(raw), "maximumFrameBytes": largest,
            "sha256": digest, "strictlyIncreasingSequences": True,
            "uniqueNonces": len(nonces), "sequenceRange": [sequences[0], sequences[-1]],
        }
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_directory", type=Path)
    parser.add_argument("--remove-raw", action="store_true")
    args = parser.parse_args()
    directory = args.capture_directory.resolve()
    results = inspect(directory)
    report = {
        "schemaVersion": 1, "inspector": "Astra parent second length-prefixed reader",
        "inspectorSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "scope": "Keyless wire structure, counters, nonce uniqueness and exact capture hashes. Does not independently decrypt or authenticate contents.",
        "directions": results, "rawCapturesRemovedAfterInspection": False,
        "physicalPixelTouched": False, "passed": True,
    }
    report_file = directory / "independent-inspection.json"
    report_file.write_text(json.dumps(report, indent=2) + "\n")
    if args.remove_raw:
        # Only these two completed, hash-checked capture files belong to this action.
        for direction, result in results.items():
            path = directory / (direction + ".bin")
            assert hashlib.sha256(path.read_bytes()).hexdigest() == result["sha256"]
        for direction in results:
            (directory / (direction + ".bin")).unlink()
        report["rawCapturesRemovedAfterInspection"] = True
        report_file.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": True, "directions": results, "rawRemoved": args.remove_raw}))
