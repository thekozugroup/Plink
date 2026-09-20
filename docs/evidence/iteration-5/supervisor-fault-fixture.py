import ast, copy, hashlib, io, json, pathlib, types
ROOT = pathlib.Path("/Users/michaelwong/Developer/Plink")
body = report["source"]["snapshot"].split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
tree = ast.parse(body)
names = {"mappings", "cleanup_android", "cleanup", "start_android", "verify_instrumentation_identity",
         "verify_local_binaries", "remaining", "run", "device", "cleanup_mac_state", "release_map"}
nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
assert {n.name for n in nodes} == names
compiled = compile(ast.Module(body=nodes, type_ignores=[]), "<snapshot-functions>", "exec")
results = []
class FakeTimeout(Exception): pass
class FakePath:
    def __init__(self, name, logs): self.name, self.logs = name, logs
    def __truediv__(self, name): return FakePath(self.name + "/" + name, self.logs)
    def open(self, mode): self.logs.append(["open", self.name, mode]); return io.StringIO()
    def write_text(self, text): self.logs.append(["file", self.name, text])
    def __str__(self): return self.name

def setup():
    log = []
    state = {"commands": [], "phases": {}, "instrumentInstalled": True,
        "reconnectInstrumentAttempted": False, "receiverSha256Before": "receiver-digest",
        "appApkSha256": "main-digest", "testApkSha256": "test-digest",
        "install": {"attempted": True, "phase": "installed"}}
    local = {"receiver": "receiver-digest", "main": "main-digest", "test": "test-digest"}
    installed = {"app.plink.android": "main-digest", "app.plink.android.test": "test-digest"}
    g = {"state": state, "children": [], "adb": "/explicit/fake/adb", "serial": "fake-emulator",
        "run_id": "00000000-0000-4000-8000-000000000005", "PHASE_TIMEOUT": 30,
        "ADB_TIMEOUT": 5, "RUN_TIMEOUT": 120, "deadline": 200, "work_deadline": 170, "phase_deadline": None,
        "time": types.SimpleNamespace(monotonic=lambda: 100),
        "out": FakePath("memory-output", log), "Path": pathlib.Path}
    for var, val in [("receiver", "receiver"), ("app_apk", "main"), ("test_apk", "test")]:
        g[var] = FakePath(val, log)
    def digest(p): log.append(["digest", p.name]); return local[p.name]
    def apk_hash(package, label): log.append(["identity", package, label]); return installed.get(package)
    def save(): log.append(["save", state.get("reconnectInstrumentAttempted"), copy.deepcopy(state["install"])])
    def packages(): log.append(["packages"]); return list(installed)
    def write(name, data): log.append(["report", name, copy.deepcopy(data)])
    def fake_device(*args, **kwargs):
        log.append(["device", list(args), kwargs])
        if args[:2] == ("uninstall", "app.plink.android.test"):
            installed.pop("app.plink.android.test", None)
            return "Success\n"
        return g.get("cleanup_output", "RECONNECT PHONE CLEANUP PASSED\n")
    def fake_run(command, **kwargs):
        log.append(["subprocess.run", command, {k:v for k,v in kwargs.items() if k == "timeout"}])
        return types.SimpleNamespace(stdout=b"RECONNECT PHONE CLEANUP PASSED\n", returncode=0)
    def fake_popen(args, **kwargs):
        assert state["reconnectInstrumentAttempted"] is True
        log.append(["Popen", args, "attempt-flag-true"])
        return types.SimpleNamespace(poll=lambda: None)
    g.update(digest=digest, apk_hash=apk_hash, save=save, packages=packages, write=write,
        redact=lambda args: args, stop_children=lambda: log.append(["stop_children"]),
        wait_for_marker=lambda *args: log.append(["wait_for_marker", args[2], args[3]]),
        subprocess=types.SimpleNamespace(run=fake_run, Popen=fake_popen, STDOUT=-2, PIPE=-1, TimeoutExpired=FakeTimeout))
    exec(compiled, g)
    g["device"] = fake_device
    return g, log, local, installed

def check(name, action):
    log = []
    try:
        details = action(log)
        results.append({"id": name, "status": "pass", "details": details, "events": log})
    except Exception as error:
        results.append({"id": name, "status": "fail", "error": repr(error), "events": log})
def raises(action, kind=RuntimeError, contains=None):
    try: action()
    except kind as e:
        if contains: assert contains in str(e), str(e)
        return str(e)
    raise AssertionError("Expected " + kind.__name__)
def external(log): return [e for e in log if e[0] in ("device", "Popen", "subprocess.run")]
def copylog(target, log): target.extend(log)

def exact_diff(log):
    current = report["source"]["snapshot"]
    edits = [
      ('    for line in device(kind, "--list", name=name).splitlines():\n        if not line.strip():\n            continue\n',
       '    for line in device(kind, "--list", name=name).splitlines():\n'),
      ('    state["reconnectInstrumentAttempted"] = True\n', ''),
      ('    if not state.get("instrumentInstalled") or not state.get("reconnectInstrumentAttempted"):\n',
       '    if not state.get("instrumentInstalled"):\n'),
      ('        "reconnectInstrumentAttempted": False,\n', '')]
    for before, after in edits:
        assert current.count(before) == 1
        current = current.replace(before, after, 1)
    baseline = (ROOT / ".a5c/artifacts/iteration5-harness-host-checks/verify-reconnect.final-0ebe64b6d19d.sh").read_text()
    assert hashlib.sha256(baseline.encode()).hexdigest() == report["source"]["baselineSha256"]
    assert current == baseline
    return {"exactlyFourIntendedChanges": True, "allOtherSourceBytesUnchanged": True}
check("exact-diff-from-final-0ebe", exact_diff)

mapping_inputs = [
 ("empty", "", []), ("LF", "\n", []), ("CRLF", "\r\n", []),
 ("whitespace", " \t\r\n \t\n", []),
 ("valid", "fake-emulator tcp:46731 tcp:46731\n", [["fake-emulator", "tcp:46731", "tcp:46731"]]),
 ("mixed-blank-valid", "\n \t\r\nfake-emulator tcp:46731 tcp:46731\r\n\t\n", [["fake-emulator", "tcp:46731", "tcp:46731"]]),
 ("malformed-one-field", "garbage\n", None),
 ("malformed-two-fields", "fake-emulator tcp:46731\n", None),
 ("malformed-four-fields", "fake-emulator tcp:46731 tcp:46731 extra\n", None)]
for kind in ("forward", "reverse"):
    for label, inventory, expected in mapping_inputs:
        def mapping_case(log, kind=kind, inventory=inventory, expected=expected):
            g, events, _, _ = setup()
            before = copy.deepcopy(g["state"])
            def device(*args, **kwargs):
                events.append(["device", list(args), kwargs]); return inventory
            g["device"] = device
            if expected is None:
                error = raises(lambda: g["mappings"](kind, "inventory.log"), contains="Invalid "+kind+" mapping inventory.")
            else:
                assert g["mappings"](kind, "inventory.log") == expected; error = None
            assert events == [["device", [kind, "--list"], {"name": "inventory.log"}]]
            assert g["state"] == before
            copylog(log, events)
            return {"input": inventory, "expectedRows": expected, "error": error, "statePreserved": True}
        check("mappings-"+kind+"-"+label, mapping_case)

for label, installed_flag, attempted in [("no-attempt", True, False), ("missing-attempt-key", True, None), ("not-installed", False, True)]:
    def skip(log, installed_flag=installed_flag, attempted=attempted):
        g, events, _, _ = setup(); g["state"]["instrumentInstalled"] = installed_flag
        if attempted is None: g["state"].pop("reconnectInstrumentAttempted")
        else: g["state"]["reconnectInstrumentAttempted"] = attempted
        before = copy.deepcopy(g["state"]); g["cleanup_android"]()
        assert not events and g["state"] == before
        return {"identityCalls": 0, "cleanupCommands": 0, "statePreserved": True}
    check("cleanup-"+label, skip)

for label, output, error_expected in [("marker-present", "RECONNECT PHONE CLEANUP PASSED\n", False), ("marker-missing", "INSTRUMENTATION_CODE: -1\n", True)]:
    def launched(log, output=output, error_expected=error_expected):
        g, events, _, _ = setup(); g["state"]["reconnectInstrumentAttempted"] = True
        g["cleanup_output"] = output; before = copy.deepcopy(g["state"])
        if error_expected: raises(g["cleanup_android"], contains="lacks explicit ownership confirmation")
        else: g["cleanup_android"]()
        calls = external(events); assert len(calls) == 1
        args = calls[0][1]; assert args[:7] == ["shell","am","instrument","-w","-e","mode","reconnectCleanup"]
        assert args[7:10] == ["-e","reconnectRunId",g["run_id"]]
        assert [e[0] for e in events[:5]] == ["digest"]*3+["identity"]*2
        assert g["state"] == before
        copylog(log, events)
        return {"identityBeforeCleanup": True, "markerRequired": True, "statePreserved": True}
    check("cleanup-attempted-"+label, launched)

for target in ("receiver", "main", "test", "installed-main", "installed-test"):
    def identity_failure(log, target=target):
        g, events, local, installed = setup(); g["state"]["reconnectInstrumentAttempted"] = True
        if target.startswith("installed-"):
            installed["app.plink.android" + (".test" if target == "installed-test" else "")] = "changed"
        else: local[target] = "changed"
        before = copy.deepcopy(g["state"])
        error = raises(g["cleanup_android"])
        assert not external(events) and g["state"] == before
        copylog(log, events)
        return {"error": error, "cleanupCommands": 0, "statePreserved": True}
    check("cleanup-refuses-changed-"+target, identity_failure)

for label in ("success", "Popen-failure", "identity-failure"):
    def start(log, label=label):
        g, events, local, installed = setup()
        if label == "Popen-failure":
            def failed(*args, **kwargs):
                assert g["state"]["reconnectInstrumentAttempted"] is True
                events.append(["Popen", "injected launch failure", "attempt-flag-true"])
                raise OSError("fake Popen failure")
            g["subprocess"].Popen = failed
        if label == "identity-failure": local["test"] = "changed"
        action = lambda: g["start_android"]("baseline", 1, 2, "fake-key", FakePath("memory-phase", events))
        if label == "Popen-failure": raises(action, OSError)
        elif label == "identity-failure": raises(action)
        else: action()
        if label == "identity-failure":
            assert g["state"]["reconnectInstrumentAttempted"] is False
            assert not external(events) and not g["children"]
        else:
            assert g["state"]["reconnectInstrumentAttempted"] is True
            saved = next(i for i,e in enumerate(events) if e[0] == "save")
            popped = next(i for i,e in enumerate(events) if e[0] == "Popen")
            assert saved < popped and events[saved][1] is True
            assert len(g["children"]) == (1 if label == "success" else 0)
        copylog(log, events)
        return {"attemptFlag": g["state"]["reconnectInstrumentAttempted"], "children": len(g["children"])}
    check("start-android-"+label, start)

for label in ("no-attempt-uninstalls", "no-attempt-changed-test-preserved", "attempted-missing-marker-reports-failure"):
    def cleanup_case(log, label=label):
        g, events, _, installed = setup()
        if label == "no-attempt-changed-test-preserved": installed["app.plink.android.test"] = "changed"
        if label == "attempted-missing-marker-reports-failure":
            g["state"]["reconnectInstrumentAttempted"] = True; g["cleanup_output"] = "no ownership marker"
        passed = g["cleanup"](0)
        result = [e[2] for e in events if e[:2] == ["report","host-cleanup.json"]][-1]
        calls = external(events)
        instrument_calls = [e for e in calls if e[0] == "device" and "instrument" in e[1]]
        uninstalls = [e for e in calls if e[0] == "device" and e[1][0] == "uninstall"]
        assert len(instrument_calls) == (1 if label.startswith("attempted") else 0)
        if label == "no-attempt-changed-test-preserved":
            assert not uninstalls and not passed and not result["passed"]
            assert g["state"]["install"]["phase"] == "installed" and "app.plink.android.test" in installed
            assert result["checks"]["testPackage"] == "failed"
        else:
            assert len(uninstalls) == 1 and g["state"]["install"]["phase"] == "absent"
            assert "app.plink.android.test" not in installed
            assert any(e[:3] == ["identity", "app.plink.android.test", "test-apk-before-uninstall"] for e in events)
            assert passed == (label == "no-attempt-uninstalls")
            assert result["checks"]["androidReconnectState"] == ("passed" if passed else "failed")
        assert g["deadline"] == 200
        copylog(log, events)
        return {"cleanupReturn": passed, "cleanupReport": result, "residualInstallState": g["state"]["install"]["phase"]}
    check("full-cleanup-"+label, cleanup_case)

for label in ("direct-command", "start-android", "cleanup-residual"):
    def deadline_case(log, label=label):
        g, events, local, installed = setup()
        # Restore actual run/device functions. Fake subprocess entry points never execute real binaries.
        exec(compile(ast.Module(body=[n for n in nodes if n.name in ("run","device")],type_ignores=[]),"<actual-device-functions>","exec"),g)
        g["deadline"] = 100; g["work_deadline"] = 90
        if label == "direct-command":
            raises(lambda: g["device"]("version", name="blocked.log"), FakeTimeout)
        elif label == "start-android":
            raises(lambda: g["start_android"]("deadline", 1, 2, "fake-key", FakePath("memory-phase",events)), FakeTimeout)
        else:
            g["state"]["reconnectInstrumentAttempted"] = True
            assert g["cleanup"](0) is False
            result = [e[2] for e in events if e[:2] == ["report","host-cleanup.json"]][-1]
            assert result["checks"]["androidReconnectState"] == "failed"
            assert result["checks"]["testPackage"] == "failed"
            assert result["cleanupExitCode"] == 1 and not result["passed"]
            assert g["state"]["install"]["phase"] == "installed"
            assert "app.plink.android.test" in installed
        assert not external(events) and g["deadline"] == 100
        copylog(log, events)
        return {"actualSubprocessCalls": 0, "hardDeadlineUnchanged": True, "residualInstallState": g["state"]["install"]["phase"]}
    check("hard-deadline-"+label, deadline_case)

report["functionLocations"] = {n.name: {"startLine": n.lineno + 6, "endLine": n.end_lineno + 6} for n in nodes}
report["results"] = results
report["summary"] = {"total": len(results), "passed": sum(r["status"] == "pass" for r in results),
                     "failed": sum(r["status"] == "fail" for r in results), "skipped": 0}
