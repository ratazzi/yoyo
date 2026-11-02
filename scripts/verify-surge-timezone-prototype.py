"""Live PID/session/socket checks against the local Yoyo Surge prototype."""
import json
import plistlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

root = Path(__file__).resolve().parent.parent
os.chdir(root)
policy_path = root / "build/state/policy.plist"
state_path = root / "build/state/daemon-state.json"
identifier = "test-surge-zone-" + uuid.uuid4().hex


def write_policy(value):
    mode = policy_path.stat().st_mode & 0o777
    with tempfile.NamedTemporaryFile(mode="wb", dir=policy_path.parent, delete=False) as output:
        plistlib.dump(value, output)
        temporary = Path(output.name)
    temporary.chmod(mode)
    temporary.replace(policy_path)


def remove_rule():
    current = plistlib.loads(policy_path.read_bytes())
    current["rules"] = [rule for rule in current["rules"] if rule["id"] != identifier]
    write_policy(current)


def wait_target(path, present):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        state = json.loads(state_path.read_text())
        if state.get("status") == "listening" and (str(path) in state.get("targets", [])) == present:
            return
        time.sleep(0.1)
    raise RuntimeError("Daemon did not reload the temporary fixture rule")


initial = plistlib.loads(policy_path.read_bytes())
if not initial.get("es_enabled"):
    raise SystemExit("Enable the ES background service first")
binary = root / "build/surge-socket-test"
subprocess.run(["/usr/bin/clang", "-fobjc-arc", "-framework", "Foundation",
                "Tests/Integration/surge-socket-prototype.m", "-o", str(binary)], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign",
                os.environ.get("SIGN_IDENTITY", "A5D59E9573A394C9AB54B3354913C818170B9948"), str(binary)], check=True)
last_path = None
try:
    for suffix, zone, policy in [("paris", "Europe/Paris", "Paris"), ("singapore", "Asia/Singapore", "Singapore"),
                                 ("la", "America/Los_Angeles", "Los_Angeles")]:
        path = root / ("build/surge-socket-test-" + suffix)
        shutil.copy2(binary, path)
        current = plistlib.loads(policy_path.read_bytes())
        current["rules"] = [rule for rule in current["rules"] if rule["id"] != identifier]
        current["rules"].append({"id": identifier, "name": "Surge PID Zone Test", "kind": "cli", "pattern": str(path),
                                 "mode": "fixed", "zone": zone, "enabled": True, "logging": True})
        write_policy(current)
        last_path = path
        wait_target(path, True)
        environment = dict(os.environ, YOYO_EXPECT_ROUTE=policy, YOYO_EXPECT_ZONE=zone)
        subprocess.run([str(path)], env=environment, check=True, timeout=25)
        deadline = time.monotonic() + 5
        while True:
            audit_path = root / "build/state/network-audit.jsonl"
            entries = [json.loads(line) for line in audit_path.read_text().splitlines()] if audit_path.exists() else []
            own = [entry for entry in entries if entry.get("process", {}).get("rule_id") == identifier
                   and entry.get("timezone") == zone]
            if any(entry["matched"] for entry in own) and any(not entry["matched"] for entry in own):
                assert all(entry["process"].get("session") and entry["process"].get("parent_pid") for entry in own)
                print(f"Network audit with launch-session identity, matched and unmatched: {zone}: PASS")
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Missing correlated network audit events")
            time.sleep(0.1)
finally:
    remove_rule()
    if last_path is not None:
        wait_target(last_path, False)
print("Live socket PID -> ES launch timezone API: PASS")
