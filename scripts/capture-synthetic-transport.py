#!/usr/bin/env python3
"""Capture unchanged encrypted frames from the isolated device test, without keys.

This is a local TCP relay, not a radio packet capture. It observes both directions
of the production transport. Raw capture is test-owned and may be removed after
independent inspection; the JSON summary retains counts and capture hashes.
"""
import argparse
import hashlib
import json
import signal
import socket
import struct
import threading
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mac-target", required=True, type=int)
    parser.add_argument("--android-target", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    fields = {"version", "sequence", "nonce", "issuedAt", "sourceDeviceId", "targetDeviceId", "cipherText", "signature"}
    markers = [b"Plink encrypted roundtrip", b"Plink synthetic", b"boundary-", bytes(range(64))]
    report = {"method": "keyless TCP relay; exact length-prefixed encrypted bytes forwarded", "directions": {}, "errors": []}

    def exact(client, count):
        data = bytearray()
        while len(data) < count:
            block = client.recv(count - len(data))
            if not block:
                raise EOFError("Incomplete synthetic frame")
            data.extend(block)
        return bytes(data)

    def relay(listener, target, direction):
        stats = {"frames": 0, "wireBytes": 0, "maximumFrameBytes": 0, "plaintextMarkerMatches": 0,
                 "unexpectedOuterFields": 0, "visibleMetadata": ["sourceDeviceId", "targetDeviceId", "sequence", "issuedAt"]}
        digest = hashlib.sha256()
        report["directions"][direction] = stats
        with (args.output / (direction + ".bin")).open("xb") as capture:
            while not stop.is_set():
                try:
                    client, _ = listener.accept()
                except socket.timeout:
                    continue
                try:
                    with client:
                        client.settimeout(5)
                        header = exact(client, 4)
                        size, = struct.unpack("!I", header)
                        if not 0 < size <= 131072:
                            raise ValueError("Frame exceeds production bound")
                        payload = exact(client, size)
                        frame = header + payload
                        with socket.create_connection(("127.0.0.1", target), timeout=5) as peer:
                            peer.sendall(frame)
                        capture.write(frame)
                        digest.update(frame)
                        stats["frames"] += 1
                        stats["wireBytes"] += len(frame)
                        stats["maximumFrameBytes"] = max(stats["maximumFrameBytes"], size)
                        stats["plaintextMarkerMatches"] += sum(marker in payload for marker in markers)
                        outer = json.loads(payload)
                        stats["unexpectedOuterFields"] += int(set(outer) != fields)
                except Exception as error:
                    report["errors"].append({"direction": direction, "error": type(error).__name__})
        stats["captureSha256"] = digest.hexdigest()

    listeners = []
    workers = []
    ports = {}
    for direction, target in [("android-to-mac", args.mac_target), ("mac-to-android", args.android_target)]:
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(8)
        listener.settimeout(0.2)
        listeners.append(listener)
        ports[direction] = listener.getsockname()[1]
        worker = threading.Thread(target=relay, args=(listener, target, direction))
        worker.start()
        workers.append(worker)
    (args.output / "ready.json").write_text(json.dumps(ports))
    stop.wait()
    for worker in workers:
        worker.join()
    for listener in listeners:
        listener.close()
    report["passed"] = not report["errors"] and all(
        x["frames"] > 0 and x["plaintextMarkerMatches"] == 0 and x["unexpectedOuterFields"] == 0
        for x in report["directions"].values())
    (args.output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
