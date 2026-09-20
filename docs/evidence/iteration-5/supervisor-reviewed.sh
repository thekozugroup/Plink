#!/usr/bin/env bash
# Emulator-only reconnect supervisor. It owns only maps, child processes, and its test APK.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "$ROOT_DIR" "${1:?Pass an exact emulator-N serial.}" "${2:?Pass a new output directory.}" "${ADB:-adb}" <<'PY'
from pathlib import Path
import base64, hashlib, ipaddress, json, os, re, shutil, socket, subprocess, sys, time, uuid

root, serial, out, adb = sys.argv[1:]
root, out = Path(root), Path(out).resolve()
if not re.fullmatch(r"emulator-[0-9]+", serial):
    raise SystemExit("Reconnect verification requires an explicit emulator-N serial.")
if out.exists() and any(out.iterdir()):
    raise SystemExit("Use a new or empty output directory; existing evidence is not owned by this run.")
out.mkdir(parents=True, exist_ok=True)

ADB_TIMEOUT, PHASE_TIMEOUT, RUN_TIMEOUT = 20, 240, 800
receiver = root / "macos/.build/debug/PlinkMacDebugReceiver"
app_apk = root / "android/build/outputs/apk/debug/android-debug.apk"
test_apk = root / "android/build/outputs/apk/androidTest/debug/android-debug-androidTest.apk"
wire_cases = root / "shared/protocol/v1/reconnect/cases.json"
network_cases = root / "shared/protocol/v1/reconnect/network-cases.json"
encrypted_vectors = root / "shared/protocol/v1/reconnect/encrypted-vectors.json"
journal = out / "host-ownership.json"
children, state, deadline, work_deadline, phase_deadline = [], None, None, None, None
run_id = str(uuid.uuid4())

def write(name, value):
    target = out / name
    temporary = target.with_suffix(target.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(target)

def save():
    write(journal.name, state)

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def source_digests():
    return {str(path.relative_to(root)): digest(path) for path in (wire_cases, network_cases, encrypted_vectors)}

def source_tree_digest():
    digestor = hashlib.sha256()
    for source_root in (root / "android/src", root / "macos/Sources"):
        for path in sorted(source_root.rglob("*")):
            if path.is_file() and path.suffix in (".kt", ".swift"):
                digestor.update(str(path.relative_to(root)).encode() + b"\0")
                digestor.update(path.read_bytes())
    return digestor.hexdigest()

def remaining(limit):
    if deadline is None:
        return limit
    active_deadline = min(value for value in (deadline, work_deadline, phase_deadline) if value is not None)
    budget = active_deadline - time.monotonic()
    if budget <= 0:
        raise subprocess.TimeoutExpired("reconnect supervisor", RUN_TIMEOUT)
    return min(limit, budget)

def redact(args):
    result, hide = [], False
    for arg in args:
        if hide:
            result.append("<redacted>")
            hide = False
        elif arg in ("sessionKeyBase64", "sessionKey"):
            result.append(arg)
            hide = True
        else:
            result.append(arg)
    return result

def run(args, name, timeout=ADB_TIMEOUT):
    command = [adb, "-s", serial, *args]
    state["commands"].append(redact(command))
    save()
    process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=remaining(timeout))
    text = process.stdout.decode(errors="replace")
    (out / name).write_text(text)
    if process.returncode:
        raise RuntimeError(f"{name} exited {process.returncode}: {text.strip()}")
    return text

def device(*args, **kwargs):
    return run(list(args), **kwargs)

def packages():
    lines = device("shell", "pm", "list", "packages", name="packages.log").splitlines()
    if not lines or any(not re.fullmatch(r"package:[A-Za-z0-9_.]+", line) for line in lines):
        raise RuntimeError("Package inventory is incomplete; test-package ownership is unknown.")
    return {line.removeprefix("package:") for line in lines}

def emulator_identity():
    qemu = device("shell", "getprop", "ro.kernel.qemu", name="emulator-qemu-property.log").strip()
    model = device("shell", "getprop", "ro.product.model", name="emulator-model-property.log").strip()
    if qemu != "1" or not model:
        raise RuntimeError("ADB target is not a verified Android emulator.")
    state["emulatorModel"] = model
    save()

def apk_hash(package, name):
    paths = device("shell", "pm", "path", package, name=name).splitlines()
    if len(paths) != 1 or not re.fullmatch(r"package:/data/app/[A-Za-z0-9_+/=.~\-]+\.apk", paths[0]):
        raise RuntimeError(f"{package} does not have one normal APK path.")
    value = device("shell", "sha256sum", paths[0].removeprefix("package:"), name=name + ".sha256").split()[0]
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise RuntimeError(f"{package} has no valid APK SHA-256.")
    return value

def mappings(kind, name):
    rows = []
    for line in device(kind, "--list", name=name).splitlines():
        if not line.strip():
            continue
        row = line.split()
        if len(row) != 3:
            raise RuntimeError(f"Invalid {kind} mapping inventory.")
        rows.append(row)
    return rows

def stop_children():
    for process in children:
        if process.poll() is None:
            process.terminate()
    for process in children:
        try:
            process.wait(timeout=remaining(2))
        except subprocess.TimeoutExpired:
            if process.poll() is None:
                process.kill()
            # Reaping uses the same absolute run budget, including during cleanup.
            process.wait(timeout=remaining(2))
    children[:] = [process for process in children if process.poll() is None]

def verify_local_binaries():
    for path, expected in ((receiver, "receiverSha256Before"), (app_apk, "appApkSha256"), (test_apk, "testApkSha256")):
        if digest(path) != state[expected]:
            raise RuntimeError(f"Local binary provenance changed: {path.name}.")

def verify_instrumentation_identity(label):
    verify_local_binaries()
    if apk_hash("app.plink.android", label + "-main-apk") != state["appApkSha256"]:
        raise RuntimeError("Main package identity changed; refusing instrumentation.")
    if apk_hash("app.plink.android.test", label + "-test-apk") != state["testApkSha256"]:
        raise RuntimeError("Test package identity changed; refusing instrumentation.")

def unavailable(port):
    with socket.socket() as probe:
        probe.settimeout(.25)
        return probe.connect_ex(("127.0.0.1", port)) != 0

def acquire_map(phase, kind, local, remote):
    before = mappings(kind, f"{phase}-{kind}-before.json")
    if any(row[1] == local for row in before):
        raise RuntimeError(f"{phase}: preexisting {kind} mapping uses {local}.")
    item = {"kind": kind, "local": local, "remote": remote, "phase": "pending"}
    state["phases"][phase]["maps"].append(item)
    save()
    try:
        device(kind, "--no-rebind", local, remote, name=f"{phase}-{kind}-acquire.log")
    except Exception:
        item["phase"] = "failed"
        save()
        raise
    after = mappings(kind, f"{phase}-{kind}-after-acquire.json")
    matches = [row for row in after if row[1] == local]
    if len(matches) != 1 or matches[0][2] != remote or (kind == "forward" and matches[0][0] != serial):
        raise RuntimeError(f"{phase}: acquired {kind} mapping identity differs from expected.")
    item["phase"] = "acquired"
    save()

def release_map(phase, item):
    if item["phase"] != "acquired":
        return
    rows = mappings(item["kind"], f"{phase}-{item['kind']}-before-release.json")
    matches = [row for row in rows if row[1] == item["local"]]
    if len(matches) != 1 or matches[0][2] != item["remote"] or (item["kind"] == "forward" and matches[0][0] != serial):
        raise RuntimeError(f"{phase}: {item['kind']} mapping identity changed; refusing removal.")
    device(item["kind"], "--remove", item["local"], name=f"{phase}-{item['kind']}-release.log")
    after = mappings(item["kind"], f"{phase}-{item['kind']}-after-release.json")
    if any(row[1] == item["local"] for row in after):
        raise RuntimeError(f"{phase}: owned {item['kind']} mapping remains.")
    item["phase"] = "absent"
    save()

def wait_for_marker(process, log_path, marker, phase):
    until = time.monotonic() + remaining(PHASE_TIMEOUT)
    while time.monotonic() < until:
        if log_path.exists() and marker in log_path.read_text(errors="replace"):
            return
        if process.poll() is not None:
            raise RuntimeError(f"{phase}: Android instrumentation exited before {marker!r}.")
        time.sleep(.05)
    raise RuntimeError(f"{phase}: Android instrumentation did not emit {marker!r} before deadline.")

def start_android(phase, phone_port, mac_port, key, phase_dir):
    verify_instrumentation_identity(phase + "-before-launch")
    log_path = phase_dir / "android-reconnect.log"
    args = [adb, "-s", serial, "shell", "am", "instrument", "-w", "-e", "mode", "reconnect",
        "-e", "sessionKeyBase64", key, "-e", "macPort", str(mac_port), "-e", "replyPort", str(phone_port),
        "-e", "reconnectRunId", run_id, "-e", "reconnectPhase", phase,
        "app.plink.android.test/app.plink.android.PlinkDeviceTestRunner"]
    state["commands"].append(redact(args))
    state["reconnectInstrumentAttempted"] = True
    save()
    remaining(PHASE_TIMEOUT)
    with log_path.open("w") as output:
        process = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT)
    children.append(process)
    wait_for_marker(process, log_path, "RECONNECT PHONE LISTENING", phase)
    return process, log_path

def start_mac(phase, phone_port, mac_port, key, phase_dir, state_dir):
    verify_local_binaries()
    remaining(PHASE_TIMEOUT)
    log_path = phase_dir / "mac-reconnect.log"
    env = dict(os.environ,
        PLINK_DEBUG_RECEIVER_MODE="reconnect",
        PLINK_DEBUG_SESSION_KEY_BASE64=key,
        PLINK_DEBUG_PAIRED_DEVICE_ID="test-pixel",
        PLINK_DEBUG_TARGET_DEVICE_ID="test-mac",
        PLINK_DEBUG_RECEIVER_PORT=str(mac_port),
        PLINK_DEBUG_REPLY_PORT=str(phone_port),
        PLINK_DEBUG_RECONNECT_EVIDENCE_DIR=str(phase_dir),
        PLINK_DEBUG_RECONNECT_STATE_DIR=str(state_dir),
        PLINK_DEBUG_RECONNECT_RUN_ID=run_id,
        PLINK_DEBUG_RECONNECT_PHASE=phase)
    with log_path.open("w") as output:
        process = subprocess.Popen([str(receiver)], env=env, stdout=output, stderr=subprocess.STDOUT)
    children.append(process)
    return process, log_path

REPORT_FIELDS = {
    "schemaVersion", "runId", "phase", "role", "passed", "proofIdHash", "hintBefore", "hintAfter",
    "ordinarySent", "ordinaryReceived", "ordinaryAdmissionInitiallyClosed", "highestReservedSequence",
    "socketObservations", "cleanupComplete",
}

def phone_report(text, phase):
    prefix = "RECONNECT PHONE REPORT:"
    reports = []
    for line in text.splitlines():
        position = line.find(prefix)
        if position >= 0:
            reports.append(line[position + len(prefix):].strip())
    if len(reports) != 1:
        raise RuntimeError(f"{phase}: expected one Android reconnect report, found {len(reports)}.")
    try:
        return json.loads(reports[0])
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{phase}: Android reconnect report is invalid JSON: {error}")

def mac_report(phase_dir, phase):
    path = phase_dir / "reconnect-mac.json"
    if not path.is_file():
        raise RuntimeError(f"{phase}: reconnect-mac.json is missing.")
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{phase}: reconnect-mac.json is invalid: {error}")

def report_integer(value, phase, field):
    if type(value) is not int:
        raise RuntimeError(f"{phase}: report {field} must be an integer.")
    return value

def numeric_host(value, phase, field):
    if not isinstance(value, str):
        raise RuntimeError(f"{phase}: report {field} must be a numeric address.")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        raise RuntimeError(f"{phase}: report {field} is not numeric.")

def validate_report(report, phase, role, phone_port, mac_port):
    if not isinstance(report, dict) or set(report) != REPORT_FIELDS:
        raise RuntimeError(f"{phase}: {role} report fields do not match the frozen schema.")
    if report_integer(report["schemaVersion"], phase, f"{role}.schemaVersion") != 1 or report["runId"] != run_id or report["phase"] != phase or report["role"] != role:
        raise RuntimeError(f"{phase}: {role} report identity does not match this run.")
    if report["passed"] is not True or report["cleanupComplete"] is not True or report["ordinaryAdmissionInitiallyClosed"] is not True:
        raise RuntimeError(f"{phase}: {role} report lacks required proof, cleanup, or admission state.")
    if report_integer(report["ordinarySent"], phase, f"{role}.ordinarySent") != 1 or report_integer(report["ordinaryReceived"], phase, f"{role}.ordinaryReceived") != 1:
        raise RuntimeError(f"{phase}: {role} report must show exactly one ordinary frame each direction.")
    proof = report["proofIdHash"]
    if not isinstance(proof, str) or not re.fullmatch(r"[0-9a-f]{64}", proof):
        raise RuntimeError(f"{phase}: {role} report has invalid proofIdHash.")
    if report["hintBefore"] != state["lastHints"][role]:
        raise RuntimeError(f"{phase}: {role} report hintBefore does not match prior committed state.")
    expected_hint = f"127.0.0.1:{phone_port if role == 'mac' else mac_port}"
    if report["hintAfter"] != expected_hint:
        raise RuntimeError(f"{phase}: {role} report hintAfter is not the current phase endpoint.")
    sequence = report_integer(report["highestReservedSequence"], phase, f"{role}.highestReservedSequence")
    if sequence <= 0 or sequence <= state["lastSequences"][role]:
        raise RuntimeError(f"{phase}: {role} report sequence did not strictly increase.")
    observations = report["socketObservations"]
    if not isinstance(observations, list) or not observations:
        raise RuntimeError(f"{phase}: {role} report lacks socket observations.")
    channels = set()
    for observed in observations:
        if not isinstance(observed, dict) or set(observed) != {"channel", "localHost", "localPort", "remoteHost", "remotePort"}:
            raise RuntimeError(f"{phase}: {role} report has invalid socket observation fields.")
        if observed["channel"] not in ("C1", "C2"):
            raise RuntimeError(f"{phase}: {role} report has an invalid socket channel.")
        channels.add(observed["channel"])
        numeric_host(observed["localHost"], phase, f"{role}.localHost")
        numeric_host(observed["remoteHost"], phase, f"{role}.remoteHost")
        local_port = report_integer(observed["localPort"], phase, f"{role}.localPort")
        remote_port = report_integer(observed["remotePort"], phase, f"{role}.remotePort")
        if not 1 <= local_port <= 65535 or not 1 <= remote_port <= 65535:
            raise RuntimeError(f"{phase}: {role} report has a socket port outside 1...65535.")
        if role == "mac" and observed["channel"] == "C1" and (remote_port != phone_port or observed["remoteHost"] != "127.0.0.1"):
            raise RuntimeError(f"{phase}: Mac C1 did not reach the phone listener.")
        if role == "mac" and observed["channel"] == "C2" and (local_port != mac_port or observed["localHost"] != "127.0.0.1"):
            raise RuntimeError(f"{phase}: Mac C2 did not use the Mac listener.")
        if role == "phone" and observed["channel"] == "C1" and (local_port != phone_port or observed["localHost"] != "127.0.0.1"):
            raise RuntimeError(f"{phase}: phone C1 did not use the phone listener.")
        if role == "phone" and observed["channel"] == "C2" and (remote_port != mac_port or observed["remoteHost"] != "127.0.0.1"):
            raise RuntimeError(f"{phase}: phone C2 did not reach the Mac listener.")
    if channels != {"C1", "C2"}:
        raise RuntimeError(f"{phase}: {role} report must include C1 and C2 observations.")
    return proof, sequence

def require_phase_result(phase, android, android_log, mac, mac_log, phase_dir):
    android_code = android.wait(timeout=remaining(PHASE_TIMEOUT))
    mac_code = mac.wait(timeout=remaining(PHASE_TIMEOUT))
    for process in (android, mac):
        if process in children:
            children.remove(process)
    android_text = android_log.read_text(errors="replace")
    mac_text = mac_log.read_text(errors="replace")
    if android_code != 0 or "RECONNECT PHONE PASSED" not in android_text:
        raise RuntimeError(f"{phase}: Android result lacks successful explicit phone proof.")
    if mac_code != 0 or "RECONNECT MAC PASSED" not in mac_text:
        raise RuntimeError(f"{phase}: Mac result lacks successful explicit Mac proof.")
    phone = phone_report(android_text, phase)
    mac = mac_report(phase_dir, phase)
    phone_proof, phone_sequence = validate_report(phone, phase, "phone", state["phases"][phase]["phonePort"], state["phases"][phase]["macPort"])
    mac_proof, mac_sequence = validate_report(mac, phase, "mac", state["phases"][phase]["phonePort"], state["phases"][phase]["macPort"])
    if phone_proof != mac_proof or phone_proof in state["proofIdHashes"]:
        raise RuntimeError(f"{phase}: proofIdHash is not shared by peers and fresh for this phase.")
    state["proofIdHashes"].append(phone_proof)
    state["lastHints"] = {"phone": phone["hintAfter"], "mac": mac["hintAfter"]}
    state["lastSequences"] = {"phone": phone_sequence, "mac": mac_sequence}
    state["phases"][phase]["phoneReport"] = phone
    state["phases"][phase]["macReport"] = mac
    state["phases"][phase]["result"] = "passed"
    save()

def run_phase(phase, phone_port, mac_port, key, state_dir):
    global phase_deadline
    phase_deadline = time.monotonic() + remaining(PHASE_TIMEOUT)
    phase_dir = out / phase
    try:
        phase_dir.mkdir()
        state["phases"][phase] = {"phonePort": phone_port, "macPort": mac_port, "maps": [], "result": "pending"}
        save()
        acquire_map(phase, "forward", f"tcp:{phone_port}", f"tcp:{phone_port}")
        acquire_map(phase, "reverse", f"tcp:{mac_port}", f"tcp:{mac_port}")
        android, android_log = start_android(phase, phone_port, mac_port, key, phase_dir)
        mac, mac_log = start_mac(phase, phone_port, mac_port, key, phase_dir, state_dir)
        require_phase_result(phase, android, android_log, mac, mac_log, phase_dir)
        stop_children()
        for item in reversed(state["phases"][phase]["maps"]):
            release_map(phase, item)
        if not unavailable(phone_port) or not unavailable(mac_port):
            raise RuntimeError(f"{phase}: phase ports remain reachable after owned cleanup.")
    finally:
        phase_deadline = None

def cleanup_android():
    if not state.get("instrumentInstalled") or not state.get("reconnectInstrumentAttempted"):
        return
    verify_instrumentation_identity("cleanup-before-launch")
    text = device("shell", "am", "instrument", "-w", "-e", "mode", "reconnectCleanup", "-e", "reconnectRunId", run_id,
        "app.plink.android.test/app.plink.android.PlinkDeviceTestRunner", name="android-reconnect-cleanup.log", timeout=PHASE_TIMEOUT)
    if "RECONNECT PHONE CLEANUP PASSED" not in text:
        raise RuntimeError("Android reconnectCleanup lacks explicit ownership confirmation.")

def cleanup_mac_state():
    if any(process.poll() is None for process in children):
        raise RuntimeError("Owned child is still running; refusing to remove its Mac state.")
    value = state.get("macStateDir")
    if value is None:
        return
    path = Path(value).resolve()
    expected = (out / "reconnect-state").resolve()
    if path != expected:
        raise RuntimeError("Mac state path does not match this run's owned directory.")
    if not path.exists():
        raise RuntimeError("Owned Mac reconnect state is missing before cleanup.")
    summary = []
    for item in sorted(path.rglob("*")):
        if item.is_symlink():
            raise RuntimeError("Refusing to remove Mac reconnect state containing a symlink.")
        if item.is_file():
            summary.append({"path": str(item.relative_to(path)), "bytes": item.stat().st_size, "sha256": digest(item)})
    write("reconnect-state-summary.json", {"path": str(path), "files": summary})
    shutil.rmtree(path)
    if path.exists():
        raise RuntimeError("Owned Mac reconnect state remains after cleanup.")

def cleanup(primary):
    global work_deadline, phase_deadline
    # Reserve cleanup time inside the original hard deadline; never renew the run.
    work_deadline, phase_deadline = None, None
    errors, checks = [], {}
    def step(name, action):
        try:
            action()
            checks[name] = "passed"
        except Exception as error:
            checks[name] = "failed"
            errors.append(name + ": " + str(error))
    step("hostProcesses", stop_children)
    for phase, record in (state or {}).get("phases", {}).items():
        for item in reversed(record.get("maps", [])):
            step(f"{phase}-{item['kind']}", lambda phase=phase, item=item: release_map(phase, item))
    step("androidReconnectState", cleanup_android)
    step("macReconnectState", cleanup_mac_state)
    if (state or {}).get("install", {}).get("attempted"):
        def uninstall():
            if "app.plink.android.test" not in packages():
                state["install"]["phase"] = "absent"
                save()
                return
            if apk_hash("app.plink.android.test", "test-apk-before-uninstall") != state["testApkSha256"]:
                raise RuntimeError("Test package identity changed; refusing uninstall.")
            device("uninstall", "app.plink.android.test", name="test-apk-uninstall.log")
            if "app.plink.android.test" in packages():
                raise RuntimeError("Owned test package remains installed.")
            state["install"]["phase"] = "absent"
            save()
        step("testPackage", uninstall)
    result = {"primaryExitCode": primary, "cleanupExitCode": int(bool(errors)), "passed": primary == 0 and not errors,
        "checks": checks, "errors": errors, "scope": "Exact adb mappings, Popen children, reconnect UUID state, and this run's test APK only."}
    write("host-cleanup.json", result)
    return not errors

status = 1
try:
    deadline = time.monotonic() + RUN_TIMEOUT
    work_deadline = deadline - min(60, RUN_TIMEOUT / 4)
    if not receiver.is_file() or not os.access(receiver, os.X_OK) or not app_apk.is_file() or not test_apk.is_file():
        raise RuntimeError("Build matching reconnect receiver, main APK, and instrumentation APK first.")
    state = {"schemaVersion": 1, "serial": serial, "runId": run_id, "commands": [], "phases": {}, "instrumentInstalled": False,
        "reconnectInstrumentAttempted": False,
        "proofIdHashes": [], "lastHints": {"mac": None, "phone": None}, "lastSequences": {"mac": 0, "phone": 0},
        "sourceDigestsBefore": source_digests(), "sourceTreeSha256Before": source_tree_digest(),
        "receiverSha256Before": digest(receiver), "appApkSha256": digest(app_apk), "testApkSha256": digest(test_apk),
        "install": {"attempted": False, "phase": "absent"}}
    save()
    device("get-state", name="device-state.log")
    emulator_identity()
    inventory = packages()
    if "app.plink.android" not in inventory:
        raise RuntimeError("Install matching debug app first.")
    if "app.plink.android.test" in inventory:
        raise RuntimeError("Existing test package is not owned; use an isolated emulator.")
    state["installedMainApkSha256Before"] = apk_hash("app.plink.android", "main-apk-before-run")
    if state["installedMainApkSha256Before"] != state["appApkSha256"]:
        raise RuntimeError("Installed main APK digest differs from android-debug.apk.")
    state["install"] = {"attempted": True, "phase": "pending"}
    save()
    try:
        device("install", "--no-streaming", "-t", str(test_apk), name="test-apk-install.log", timeout=PHASE_TIMEOUT)
    except Exception:
        state["install"]["phase"] = "failed"
        save()
        raise
    state["install"]["phase"] = "acquired"
    save()
    if apk_hash("app.plink.android.test", "test-apk-installed") != state["testApkSha256"]:
        raise RuntimeError("Installed test APK digest differs from the input APK.")
    state["instrumentInstalled"] = True
    state["install"]["phase"] = "verified"
    state["installedTestApkSha256Before"] = apk_hash("app.plink.android.test", "test-apk-before-run")
    save()
    key = base64.b64encode(os.urandom(32)).decode()
    durable_state = out / "reconnect-state"
    durable_state.mkdir()
    state["macStateDir"] = str(durable_state.resolve())
    save()
    run_phase("A", 46731, 46732, key, durable_state)
    run_phase("B", 46741, 46742, key, durable_state)
    run_phase("B-restart", 46741, 46742, key, durable_state)
    state["sourceDigestsAfter"] = source_digests()
    state["sourceTreeSha256After"] = source_tree_digest()
    state["receiverSha256After"] = digest(receiver)
    state["appApkSha256After"] = digest(app_apk)
    state["testApkSha256After"] = digest(test_apk)
    state["installedTestApkSha256After"] = apk_hash("app.plink.android.test", "test-apk-after-run")
    state["installedMainApkSha256After"] = apk_hash("app.plink.android", "main-apk-after-run")
    if state["sourceDigestsAfter"] != state["sourceDigestsBefore"] or state["sourceTreeSha256After"] != state["sourceTreeSha256Before"] or state["receiverSha256After"] != state["receiverSha256Before"] or state["appApkSha256After"] != state["appApkSha256"] or state["testApkSha256After"] != state["testApkSha256"] or state["installedMainApkSha256After"] != state["installedMainApkSha256Before"] or state["installedMainApkSha256After"] != state["appApkSha256"] or state["installedTestApkSha256After"] != state["installedTestApkSha256Before"]:
        raise RuntimeError("Source, receiver, or installed test APK provenance changed during verification.")
    save()
    status = 0
except subprocess.TimeoutExpired:
    status = 124
    print("Reconnect verification exceeded its host deadline.", file=sys.stderr)
except Exception as error:
    print(type(error).__name__ + ": " + str(error), file=sys.stderr)
finally:
    if state is not None and not cleanup(status):
        status = status or 1
if status == 0:
    print("RECONNECT SUPERVISOR PASSED: A, B, and B-restart had explicit phone and Mac proof, process success, provenance, and owned cleanup.")
raise SystemExit(status)
PY
