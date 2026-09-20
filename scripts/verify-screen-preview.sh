#!/usr/bin/env bash
# Normal Android consent must be operated on this task's isolated emulator.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL="${1:?Pass the exact serial of the isolated API34+ emulator.}"
OUT="${2:-$ROOT_DIR/build/screen-verification}"
python3 - "$ROOT_DIR" "$SERIAL" "$OUT" "${ADB:-adb}" <<'PY'
from pathlib import Path
import datetime, hashlib, json, os, re, shlex, signal, subprocess, sys
import xml.etree.ElementTree as ET
root, serial, output, adb = sys.argv[1:]
root, output = Path(root), Path(output).resolve()
if not re.fullmatch(r'emulator-[0-9]+', serial):
    raise SystemExit('This synthetic screen test is emulator-only.')
if output.exists() and any(output.iterdir()):
    raise SystemExit('Use a fresh screen evidence directory.')
output.mkdir(parents=True, exist_ok=True)

def run(args, timeout=20):
    process = subprocess.Popen(args, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        data, _ = process.communicate(timeout=timeout)
    except BaseException:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, args, output=data.decode(errors='replace'))
    return data.decode().strip()
def device(*args):
    return run([adb, '-s', serial, *args])
def app_script(script):
    # shell protocol propagates the remote exit code; quote the complete script once.
    command = 'run-as app.plink.android sh -c '+shlex.quote(script)
    return device('shell', '-T', command)
def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()
def write(name, value):
    target = output/name
    temporary = target.with_suffix(target.suffix+'.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n')
    temporary.replace(target)
def app_state():
    # Read only the synthetic session directories and the preferences this test changes.
    hashes = app_script('set -e; for d in files/transport-state files/event-outbox; do if [ -d "$d" ]; then for f in "$d"/*; do if [ -f "$f" ]; then sha256sum "$f"; fi; done; fi; done')
    prefs = app_script('set -e; if [ -f shared_prefs/feature_settings.xml ]; then cat shared_prefs/feature_settings.xml; else echo ABSENT; fi')
    values = None if prefs == 'ABSENT' else sorted(
        (e.tag, e.attrib.get('name'), e.attrib.get('value'), e.text) for e in ET.fromstring(prefs))
    # An absent prefs file and an empty map have the same restored key state.
    return {'stateFiles': sorted(hashes.splitlines()), 'featurePreferences': values or []}

def projection_idle(text):
    return bool(re.search(r'(?:mProjectionGrant\s*[:=]|Media Projection:)\s*null(?:\s|$)', text))

model = device('shell', 'getprop', 'ro.product.model')
api = int(device('shell', 'getprop', 'ro.build.version.sdk'))
if not model.startswith('sdk_gphone') or api < 34:
    raise SystemExit('Use a dedicated sdk_gphone API34+ emulator with no saved Plink pairings.')
before_projection = device('shell', 'dumpsys', 'media_projection')
(output/'projection-before.log').write_text(before_projection+'\n')
if not projection_idle(before_projection):
    raise SystemExit('An existing projection is active; preserve it and use an idle isolated emulator.')
installed = device('shell', 'pm', 'path', 'app.plink.android').splitlines()
if len(installed) != 1 or not re.fullmatch(r'package:/data/app/[A-Za-z0-9_+/=.~\-]+\.apk', installed[0]):
    raise SystemExit('Require one normal installed debug APK for exact binary binding.')
installed_hash = device('shell', 'sha256sum', installed[0].removeprefix('package:')).split()[0]
local_apk = root/'android/build/outputs/apk/debug/android-debug.apk'
if installed_hash != digest(local_apk):
    raise SystemExit('Installed Plink APK differs from the current build; no capture was started.')
before = app_state()
write('app-state-before.json', before)
source_paths = run(['git', '-C', str(root), 'ls-files', '-co', '--exclude-standard', '-z']).split('\0')
sources = {p: digest(root/p) for p in source_paths if p and (root/p).is_file() and
    (p.startswith(('android/src/', 'macos/Sources/', 'macos/Tests/', 'scripts/', 'shared/', 'gradle/')) or
     p in ['build.gradle.kts','settings.gradle.kts','android/build.gradle.kts','macos/Package.swift'])}
manifest = {
    'startedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'commit': run(['git','-C',str(root),'rev-parse','HEAD']), 'sourceSHA256': sources,
    'installedDebugAPKSHA256': installed_hash,
    'testAPKSHA256': digest(root/'android/build/outputs/apk/androidTest/debug/android-debug-androidTest.apk'),
    'macReceiverSHA256': digest(root/'macos/.build/debug/PlinkMacDebugReceiver'),
    'emulator': {'serial':serial,'model':model,'api':api,'build':device('shell','getprop','ro.build.fingerprint')},
    'macOS':run(['sw_vers']), 'adb':run([adb,'version']),
    'topology':'Owned emulator 10.0.2.2 to loopback Mac receiver; adb forward for reverse direction',
    'normalConsentRequired':True, 'nativeMacWindowVerified':False,'physicalPixelVerified':False,
}
write('manifest.json', manifest)
print('Use Plink Share and normal Android consent on the owned emulator; select its entire screen.', flush=True)
print('No capture token or permission is injected. Host instrumentation deadline: 120 seconds.', flush=True)
status, cleanup_errors, forced = 1, [], False
checks = {}
def step(name, action):
    try:
        value = action()
        checks[name] = 'passed'
        return value
    except Exception as error:
        checks[name] = 'failed'
        cleanup_errors.append(name+': '+type(error).__name__+': '+str(error))
        return None

def projection_check(name):
    text = device('shell','dumpsys','media_projection')
    (output/name).write_text(text+'\n')
    return projection_idle(text)

def service_check():
    text = device('shell','dumpsys','activity','services','app.plink.android')
    (output/'services-after.log').write_text(text+'\n')
    if 'ServiceRecord{' in text and 'ScreenProjectionService' in text:
        raise RuntimeError('Screen projection service remains registered.')

def state_check():
    after = app_state(); write('app-state-after.json', after)
    if after != before:
        raise RuntimeError('Session files or preferences were not restored; preserve diagnostics for targeted recovery.')

def host_check():
    host = json.loads((output/'host-cleanup.json').read_text())
    if not host['passed']: raise RuntimeError('Inner test or owned cleanup failed.')

def marker_check():
    if 'SCREEN TEST CLEANUP PASSED' not in (output/'android-roundtrip.log').read_text():
        raise RuntimeError('Android did not confirm quiescence and owned-state cleanup.')

try:
    process = subprocess.Popen([str(root/'scripts/verify-device.sh'), serial, str(output), 'screen'], start_new_session=True)
    try: status = process.wait(timeout=260)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL); process.wait(); status=124
        cleanup_errors.append('Outer host deadline expired; inner cleanup did not finish.')
except Exception as error:
    cleanup_errors.append(type(error).__name__+': '+str(error))
finally:
    # Recovery uses persisted exact ownership even if the inner supervisor was killed.
    # Each operation is independent: a diagnostic failure never skips another cleanup.
    ownership = step('ownershipInventory', lambda: json.loads((output/'host-ownership.json').read_text())) if (output/'host-ownership.json').exists() else {}
    capture_attempted = bool(ownership and ownership.get('instrumentStarted'))
    idle = step('projection', lambda: projection_check('projection-after.log'))
    if capture_attempted and (status == 124 or idle is not True):
        forced = True
        step('forceStop', lambda: device('shell','am','force-stop','app.plink.android'))
        idle = step('projectionAfterForceStop', lambda: projection_check('projection-after-force-stop.log'))
    if idle is not True: cleanup_errors.append('Projection release is unconfirmed.')
    if (output/'host-ownership.json').exists():
        step('ownedArtifactRecovery', lambda: run([str(root/'scripts/verify-device.sh'), serial,
            str(output), 'screen', 'recover'], timeout=200))
    step('services', service_check)
    step('appState', state_check)
    step('hostCleanup', host_check)
    step('androidCleanupMarker', marker_check)
    if forced: cleanup_errors.append('Forced termination attempted; orderly capture release is unverified.')
    passed = status == 0 and not cleanup_errors
    write('final-result.json', {'passed':passed,'testExitCode':status,'cleanupErrors':cleanup_errors,
        'checks':checks, 'forcedProcessStop':forced,'manifest':'manifest.json','manifestSHA256':digest(output/'manifest.json'),
        'pixelSubResult':'screen-frames/summary.json','nativeMacWindowVerified':False,'physicalPixelVerified':False})
    print('PASS: consented synthetic screen capture, decoded pixels and verified cleanup.' if passed else
          'FAIL: see final-result.json and retained cleanup diagnostics.', flush=True)
raise SystemExit(0 if passed else 1)
PY
