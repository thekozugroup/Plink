#!/usr/bin/env bash
# Isolated synthetic replies and files.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "$ROOT_DIR" "${1:?Pass the exact adb serial.}" "${2:-$ROOT_DIR/build/device-verification}" "${3:-roundtrip}" "${ADB:-adb}" "${4:-run}" <<'PY'
from pathlib import Path
import base64, hashlib, ipaddress, json, os, re, signal, socket, subprocess, sys, time

root, serial, out, mode, adb, operation = sys.argv[1:]
root, out = Path(root), Path(out).resolve()
if mode not in ('roundtrip', 'files') or operation not in ('run', 'recover'):
    raise SystemExit('Invalid verification mode or operation.')
lan_mac = os.environ.get('PLINK_TEST_MAC_HOST')
lan_android = os.environ.get('PLINK_TEST_ANDROID_HOST')
lan = bool(lan_mac or lan_android)
if operation == 'run' and lan:
    if not (lan_mac and lan_android) or mode != 'files' or os.environ.get('PLINK_CAPTURE_TRANSPORT') == '1':
        raise SystemExit('LAN requires both device addresses, files mode, and capture disabled.')
    private_networks = [ipaddress.ip_network(value) for value in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
    try:
        if not all(any(ipaddress.IPv4Address(value) in network for network in private_networks)
                   for value in (lan_mac, lan_android)):
            raise ValueError()
    except ValueError:
        raise SystemExit('LAN addresses must be explicit private IPv4 addresses.')
out.mkdir(parents=True, exist_ok=True)
journal = out/'host-ownership.json'
ADB_TIMEOUT = 20
INSTRUMENT_TIMEOUT = 940 if mode == 'files' else 120
RUN_TIMEOUT = 1100 if mode == 'files' else 240
receiver = root/'macos/.build/debug/PlinkMacDebugReceiver'
test_apk = root/'android/build/outputs/apk/androidTest/debug/android-debug-androidTest.apk'
state = None
children = []
deadline = None

def write(name, value):
    target = out/name
    temporary = target.with_suffix(target.suffix+'.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n')
    temporary.replace(target)

def save():
    write(journal.name, state)

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def run(args, timeout=ADB_TIMEOUT, log=None, env=None):
    if deadline is not None:
        timeout = min(timeout, max(0.01, deadline-time.monotonic()))
    # Children stay in the supervisor's group so the outer deadline kills them too.
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    children.append(process)
    try:
        data, _ = process.communicate(timeout=timeout)
    except BaseException:
        process.kill()
        data, _ = process.communicate()
        if log: (out/log).write_bytes(data)
        raise
    finally:
        children.remove(process)
    text = data.decode(errors='replace').strip()
    if log: (out/log).write_text(text+'\n')
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, args, output=text)
    return text

def device(*args, **kwargs):
    return run([adb, '-s', serial, *args], **kwargs)

def packages():
    # A successful inventory and absence are separate facts. Never infer absence from failure.
    lines = device('shell', 'pm', 'list', 'packages').splitlines()
    if not lines or any(not re.fullmatch(r'package:[A-Za-z0-9_.]+', x) for x in lines):
        raise RuntimeError('Invalid package inventory; ownership is unknown.')
    return {x.removeprefix('package:') for x in lines}

def apk_hash(package):
    paths = device('shell', 'pm', 'path', package).splitlines()
    if len(paths) != 1 or not re.fullmatch(r'package:/data/app/[A-Za-z0-9_+/=.~\-]+\.apk', paths[0]):
        raise RuntimeError('Require one normal installed APK for exact ownership.')
    result = device('shell', 'sha256sum', paths[0].removeprefix('package:'))
    value = result.split()[0] if result else ''
    if not re.fullmatch(r'[0-9a-f]{64}', value): raise RuntimeError('Invalid APK hash.')
    return value

def mappings(kind):
    rows = []
    for line in device(kind, '--list').splitlines():
        row = line.split()
        if len(row) != 3: raise RuntimeError('Invalid mapping inventory.')
        rows.append(row)
    return rows

def stop_children():
    # Only Popen objects created by this invocation; never stale PIDs from a prior run.
    for process in children:
        if process.poll() is None: process.terminate()
    for process in children:
        try: process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=2)
    children.clear()

def cleanup(primary):
    global deadline
    deadline = None
    errors, checks = [], {}
    def step(name, action):
        try:
            action(); checks[name] = 'passed'
        except Exception as error:
            checks[name] = 'failed'; errors.append(name+': '+str(error))
    step('hostProcesses', stop_children)
    for kind in ('forward', 'reverse'):
        item = state.get(kind)
        if not item or item['phase'] == 'failed': continue
        def remove_mapping(kind=kind, item=item):
            rows = mappings(kind)
            write(kind+'s-before-cleanup.json', rows)
            candidates = [row for row in rows if row[1] == item['local'] and
                          (kind == 'reverse' or row[0] == serial)]
            if candidates:
                if item['phase'] == 'absent':
                    raise RuntimeError('Released mapping was replaced; refusing removal.')
                if len(candidates) != 1 or candidates[0][2] != item['remote']:
                    raise RuntimeError('Mapping identity changed; refusing removal.')
                device(kind, '--remove', item['local'], log=kind+'-cleanup.log')
            after = mappings(kind)
            write(kind+'s-after.json', after)
            if any(row[1] == item['local'] and (kind == 'reverse' or row[0] == serial) for row in after):
                raise RuntimeError('Owned mapping remains.')
            item['phase'] = 'absent'; save()
        step(kind, remove_mapping)
    if state.get('install', {}).get('phase') not in (None, 'failed'):
        def remove_package():
            if 'app.plink.android.test' in packages():
                if state['install']['phase'] == 'absent':
                    raise RuntimeError('Released test package was replaced; refusing uninstall.')
                if apk_hash('app.plink.android.test') != state['testAPKSHA256']:
                    raise RuntimeError('Test APK identity changed; refusing uninstall.')
                device('uninstall', 'app.plink.android.test', log='test-package-cleanup.log')
            remaining = packages()
            write('test-packages-after.json', sorted(remaining))
            if 'app.plink.android.test' in remaining: raise RuntimeError('Owned test package remains.')
            state['install']['phase'] = 'absent'; save()
        step('testPackage', remove_package)
    result = {'primaryExitCode':primary, 'cleanupExitCode':int(bool(errors)),
              'passed':primary == 0 and not errors, 'checks':checks, 'errors':errors,
              'scope':'Owned test package and exact transport mappings'}
    write('host-recovery.json' if operation == 'recover' else 'host-cleanup.json', result)
    return not errors

if operation == 'recover':
    state = json.loads(journal.read_text())
    if state['serial'] != serial or state['mode'] != mode or state['schemaVersion'] != 1:
        raise SystemExit('Ownership journal does not match this invocation.')
    raise SystemExit(0 if cleanup(0) else 1)

# Do not reuse a prior ownership record or evidence from another attempt.
if journal.exists(): raise SystemExit('Use a fresh output directory; ownership record already exists.')
status = 1
try:
    deadline = time.monotonic()+RUN_TIMEOUT
    if not receiver.is_file() or not os.access(receiver, os.X_OK) or not test_apk.is_file():
        raise RuntimeError('Build matching receiver and instrumentation artifacts first.')
    device('get-state')
    inventory = packages()
    if 'app.plink.android' not in inventory: raise RuntimeError('Install the matching debug app first.')
    if 'app.plink.android.test' in inventory: raise RuntimeError('Preserve the existing test package; use an isolated device.')
    state = {'schemaVersion':1, 'serial':serial, 'mode':mode, 'transport':'lan' if lan else 'adb',
             'testAPKSHA256':digest(test_apk), 'testPackageAbsentBefore':True}
    save()
    def port():
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); return sock.getsockname()[1]
    mac_port, phone_port, forward_port = port(), 45791, port()
    if not lan:
        if any(row[1] == 'tcp:'+str(forward_port) for row in mappings('forward')):
            raise RuntimeError('Selected forward already exists.')
        state['forward'] = {'local':'tcp:'+str(forward_port), 'remote':'tcp:'+str(phone_port), 'phase':'pending'}
        save()
        try: device('forward', '--no-rebind', state['forward']['local'], state['forward']['remote'])
        except subprocess.CalledProcessError as error:
            if 'cannot rebind' in str(error.output):
                state['forward']['phase']='failed'; save()
            raise
        state['forward']['phase']='acquired'; save()
    phone_target, mac_target = mac_port, forward_port
    if os.environ.get('PLINK_CAPTURE_TRANSPORT') == '1':
        if (out/'capture').exists(): raise RuntimeError('Use a fresh capture directory.')
        capture_log = (out/'capture.log').open('w')
        capture = subprocess.Popen([sys.executable, str(root/'scripts/capture-synthetic-transport.py'),
            '--mac-target',str(mac_port),'--android-target',str(forward_port),'--output',str(out/'capture')],
            stdout=capture_log, stderr=subprocess.STDOUT)
        children.append(capture)
        ready = out/'capture/ready.json'
        until = time.monotonic()+5
        while not ready.exists():
            if capture.poll() is not None or time.monotonic() >= until: raise RuntimeError('Capture proxy not ready.')
            time.sleep(.05)
        targets = json.loads(ready.read_text())
        phone_target, mac_target = targets['android-to-mac'], targets['mac-to-android']
    if not lan and not serial.startswith('emulator-'):
        if any(row[1] == 'tcp:45790' for row in mappings('reverse')): raise RuntimeError('Reverse port already exists.')
        state['reverse'] = {'local':'tcp:45790','remote':'tcp:'+str(phone_target),'phase':'pending'}; save()
        try: device('reverse','--no-rebind','tcp:45790',state['reverse']['remote'])
        except subprocess.CalledProcessError as error:
            if 'cannot rebind' in str(error.output):
                state['reverse']['phase']='failed'; save()
            raise
        state['reverse']['phase']='acquired'; save()
    key = base64.b64encode(os.urandom(32)).decode()
    env = dict(os.environ, PLINK_DEBUG_SESSION_KEY_BASE64=key, PLINK_DEBUG_PAIRED_DEVICE_ID='test-pixel',
        PLINK_DEBUG_TARGET_DEVICE_ID='test-mac', PLINK_DEBUG_RECEIVER_MODE=mode,
        PLINK_DEBUG_RECEIVER_PORT=str(mac_port), PLINK_DEBUG_REPLY_PORT=str(phone_port if lan else mac_target),
        PLINK_DEBUG_REPLY_HOST=lan_android if lan else '127.0.0.1')
    receiver_log = (out/'mac-roundtrip.log').open('w')
    receiver_process = subprocess.Popen([str(receiver)], env=env, stdout=receiver_log, stderr=subprocess.STDOUT)
    children.append(receiver_process)
    # Persist intent before mutation. Lost install acknowledgment is reconciled by APK hash.
    state['install'] = {'phase':'pending'}; save()
    try: device('install', '--no-streaming', '-t', str(test_apk), log='test-install.log')
    except subprocess.CalledProcessError as error:
        if 'INSTALL_FAILED_ALREADY_EXISTS' in str(error.output):
            state['install']['phase']='failed'; save()
        raise
    state['install']['phase']='acquired'; save()
    if apk_hash('app.plink.android.test') != state['testAPKSHA256']: raise RuntimeError('Installed test APK mismatch.')
    test_host = lan_mac if lan else ('10.0.2.2' if serial.startswith('emulator-') else '127.0.0.1')
    test_port = mac_port if lan else (phone_target if serial.startswith('emulator-') else 45790)
    state['instrumentStarted']=True; save()
    device('shell','am','instrument','-w','-e','mode',mode,'-e','macHost',test_host,
        '-e','macPort',str(test_port),'-e','replyPort',str(phone_port),'-e','sessionKey',key,
        'app.plink.android.test/app.plink.android.PlinkDeviceTestRunner',
        timeout=INSTRUMENT_TIMEOUT, log='android-roundtrip.log')
    if 'PLINK DEVICE CHECKS PASSED' not in (out/'android-roundtrip.log').read_text(): raise RuntimeError('Android checks failed.')
    if receiver_process.wait(timeout=max(.01,deadline-time.monotonic())) != 0: raise RuntimeError('Receiver failed.')
    if os.environ.get('PLINK_CAPTURE_TRANSPORT') == '1':
        capture.terminate(); capture.wait(timeout=5)
        if not json.loads((out/'capture/summary.json').read_text())['passed']: raise RuntimeError('Wire capture failed.')
    expected = {'files':'FILE ROUNDTRIP PASSED','roundtrip':'ROUNDTRIP PASSED'}[mode]
    if expected not in (out/'mac-roundtrip.log').read_text(): raise RuntimeError('Receiver checks failed.')
    status = 0
except subprocess.TimeoutExpired:
    status = 124; print('Test command exceeded its host deadline.', file=sys.stderr)
except subprocess.CalledProcessError as error:
    print('Command failed with exit '+str(error.returncode)+': '+str(error.output), file=sys.stderr)
except Exception as error:
    print(type(error).__name__+': '+str(error), file=sys.stderr)
finally:
    if state is not None:
        if not cleanup(status): status = status or 1
if status == 0:
    print('SUBCHECK PASS: '+mode+' synthetic encrypted roundtrip and owned host cleanup.')
    print('Not tested: pairing UI, Notification Center interaction, actual messaging recipient, cellular calls/audio.')
raise SystemExit(status)
PY
