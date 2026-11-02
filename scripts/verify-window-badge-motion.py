"""Exercise real scrolling and window geometry changes against a diagnostic Yoyo build."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

root = Path(__file__).resolve().parent.parent
os.chdir(root)
policy_path = root / "build/state/policy.json"
identifier = "test-badge-motion-" + uuid.uuid4().hex


def update_rule(rule=None):
    policy = json.loads(policy_path.read_text())
    policy["rules"] = [entry for entry in policy["rules"] if entry["id"] != identifier]
    if rule:
        policy["rules"].append(rule)
    mode = policy_path.stat().st_mode & 0o777
    with tempfile.NamedTemporaryFile(mode="w", dir=policy_path.parent, delete=False) as output:
        json.dump(policy, output)
        temporary = Path(output.name)
    temporary.chmod(mode)
    temporary.replace(policy_path)


with tempfile.TemporaryDirectory(prefix="badge-motion-", dir=root / "build") as temporary:
    bundle = Path(temporary) / "BadgeMotionFixture.app"
    binary = bundle / "Contents/MacOS/badge-motion-fixture"
    binary.parent.mkdir(parents=True)
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "yoyo.hola.ac.badge-motion-fixture",
        "CFBundleExecutable": binary.name, "CFBundleName": "Badge Motion Fixture", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1"}))
    subprocess.run(["/usr/bin/swiftc", "-parse-as-library", "Tests/Integration/window-badge-drag.swift",
                    "-framework", "AppKit", "-o", str(binary)], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "A5D59E9573A394C9AB54B3354913C818170B9948", str(bundle)], check=True)
    try:
        update_rule({"id": identifier, "name": "Badge Motion Test", "kind": "app", "pattern": str(bundle),
                     "mode": "fixed", "zone": "Asia/Tokyo", "enabled": True, "logging": False})
        deadline = time.monotonic() + 10
        while str(bundle) not in json.loads((root / "build/state/daemon-state.json").read_text()).get("targets", []):
            if time.monotonic() > deadline:
                raise RuntimeError("Daemon did not load the fixture rule")
            time.sleep(0.1)
        log = root / "build/evidence/window-badge-motion.log"
        log.write_text("")
        result = subprocess.run(["/usr/bin/open", "-W", "-n", "--stdout", str(log), "--stderr", str(log),
                                 str(bundle), "--args", str(root)], capture_output=True, text=True, timeout=20)
        output = log.read_text()
        print(output, end="")
        if result.returncode or "FAIL" in output or output.count(": PASS") != 6:
            print(result.stderr)
            raise RuntimeError("Window motion regression failed")
    finally:
        update_rule()
