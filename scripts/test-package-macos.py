#!/usr/bin/env python3
"""Check staged macOS packaging with controlled build/sign/archive dependencies.

Run on macOS: python3 scripts/test-package-macos.py
Requires macOS /usr/bin/python3, plutil, xattr, /bin/bash and /bin/mv.
Does not build Swift, sign an app, install, launch, or modify the real build output.
"""

import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

STUB = '''#!/usr/bin/python3
import os,sys,pathlib,plistlib,subprocess,zipfile,signal
name=pathlib.Path(sys.argv[0]).name; args=sys.argv[1:]; fail=os.environ.get('CHECK_FAIL','')
final=pathlib.Path(os.environ['CHECK_FINAL']).resolve(); old=final/'old-marker'
prior=os.environ['CHECK_PRIOR']=='1'
def unchanged():
 assert (old.read_text()=='old app') if prior else not final.exists(),'final changed before publication'
if name=='swift': sys.exit(0)
if name=='iconutil':
 p=pathlib.Path(args[args.index('-o')+1]);p.mkdir();(p/'icon_16x16.png').write_bytes(b'fixture');sys.exit(0)
if name=='xcrun':
 p=pathlib.Path(args[args.index('--compile')+1]);(p/'Assets.car').write_bytes(b'fixture');(p/'AppIcon.icns').write_bytes(b'fixture')
 pathlib.Path(args[args.index('--output-partial-info-plist')+1]).write_bytes(plistlib.dumps({'CFBundleIconFile':'AppIcon','CFBundleIconName':'AppIcon'}));sys.exit(0)
if name=='codesign':
 bundle=pathlib.Path(args[-1]);assert bundle.name=='bundle',str(bundle)
 unchanged()
 info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes());assert info['CFBundleIconFile']=='AppIcon'
 mode='verify' if '--verify' in args else 'sign' if '--force' in args else 'entitlements'
 if mode==fail:sys.exit(71)
 sys.exit(0)
if name=='ditto':
 unchanged(); bundle=pathlib.Path(args[-2]);assert bundle.name=='PlinkMac.app'
 if fail=='zip':sys.exit(72)
 with zipfile.ZipFile(args[-1],'w') as z:z.write(bundle/'Contents/Info.plist','PlinkMac.app/Contents/Info.plist')
 sys.exit(0)
if name=='mv':
 src=pathlib.Path(args[-2]);dst=pathlib.Path(args[-1])
 if fail=='publishApp' and src.name=='PlinkMac.app' and dst==final:sys.exit(73)
 if fail=='publishZip' and dst.name=='PlinkMac.app.zip':sys.exit(74)
 result=subprocess.call(['/bin/mv']+args)
 if fail.startswith('postZipSignal') and dst.name=='PlinkMac.app.zip' and result==0:
  assert not src.exists() and dst.is_file()
  pathlib.Path(os.environ['CHECK_SIGNAL_PROOF']).write_text('renamed-before-signal')
  os.kill(os.getppid(),signal.SIGTERM)
 sys.exit(result)
'''

def main():
    if sys.platform != "darwin":
        raise SystemExit("This packaging check requires macOS tools; run it on a Mac.")
    source = pathlib.Path(__file__).resolve().parent / "package-macos.sh"
    results = []
    expected_exits = {"sign": 71, "verify": 71, "zip": 72,
                      "publishApp": 73, "publishZip": 74, "success": 0,
                      "postZipSignalWithPrior": 143, "postZipSignalNoPrior": 143}
    with tempfile.TemporaryDirectory(prefix="plink-package-check-") as directory:
        root = pathlib.Path(directory)
        tools = root / "bin"
        tools.mkdir()
        for name in ["swift", "iconutil", "xcrun", "codesign", "ditto", "mv"]:
            tool = tools / name
            tool.write_text(STUB)
            tool.chmod(0o755)
        for mode, expected_exit in expected_exits.items():
            repo = root / mode
            (repo / "scripts").mkdir(parents=True)
            (repo / "macos/.build/release").mkdir(parents=True)
            resources = repo / "macos/Resources"
            resources.mkdir()
            shutil.copyfile(source, repo / "scripts/package-macos.sh")
            (resources / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "test.fixture", "CFBundleIconFile": "Plink.icns",
                "LSMinimumSystemVersion": "14.0"
            }))
            for name in ["Plink.icns", "PlinkMac.entitlements"]:
                (resources / name).write_text("fixture")
            (repo / "macos/.build/release/PlinkMac").write_text("fixture executable")
            output = repo / "custom output"
            app = output / "PlinkMac.app"
            prior = mode != "postZipSignalNoPrior"
            output.mkdir()
            if prior:
                app.mkdir()
                (app / "old-marker").write_text("old app")
            (repo / "build").mkdir()
            archive = repo / "build/PlinkMac.app.zip"
            if prior:
                archive.write_text("old zip")
            signal_proof = repo / "signal-proof"
            environment = os.environ | {
                "PATH": str(tools) + ":" + os.environ["PATH"],
                "PLINK_MACOS_APP_DIR": str(app), "CHECK_FINAL": str(app), "CHECK_FAIL": mode,
                "CHECK_PRIOR": "1" if prior else "0", "CHECK_SIGNAL_PROOF": str(signal_proof)
            }
            process = subprocess.run(["/bin/bash", str(repo / "scripts/package-macos.sh")],
                                     env=environment, capture_output=True, text=True)
            assert process.returncode == expected_exit, (mode, process.returncode, process.stdout, process.stderr)
            if mode.startswith("postZipSignal"):
                assert signal_proof.read_text() == "renamed-before-signal"
            if mode == "success" or mode.startswith("postZipSignal"):
                assert not (app / "old-marker").exists()
                info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                assert info["CFBundleIconFile"] == "AppIcon"
                with zipfile.ZipFile(archive) as zipped:
                    assert zipped.namelist() == ["PlinkMac.app/Contents/Info.plist"]
                    assert zipped.read("PlinkMac.app/Contents/Info.plist") == (app / "Contents/Info.plist").read_bytes()
            else:
                assert (app / "old-marker").read_text() == "old app", mode
                assert archive.read_text() == "old zip", mode
            assert not list(output.glob(".plink-package.*")), mode
            assert not list((repo / "build").glob(".plink-package-zip.*")), mode
            results.append({"case": mode, "exit": process.returncode, "assertions": "passed"})
    assert not root.exists()
    print(json.dumps({
        "scope": "actual script with controlled dependencies; not real signature proof",
        "temporaryDirectoryRemoved": True, "cases": results
    }, indent=2))


if __name__ == "__main__":
    main()
