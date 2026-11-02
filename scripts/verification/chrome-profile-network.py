"""Compare real socket ownership across Chrome profiles and user-data directories."""
import json
import os
import plistlib
from pathlib import Path
import signal
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.request

root = Path(__file__).resolve().parents[2]
chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
evidence = root / "build/evidence/chrome-profiles"
evidence.mkdir(parents=True, exist_ok=True)
arrived = threading.Condition()
connections = {}
release = threading.Event()


class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        data = b""
        try:
            while b"\r\n\r\n" not in data and len(data) < 16384:
                chunk = self.request.recv(4096)
                if not chunk:
                    return
                data += chunk
            first = data.decode("latin1").split("\r\n", 1)[0]
            if first.startswith("CONNECT "):
                host = first.split()[1].split(":")[0]
                if host.endswith(".yoyo.invalid"):
                    with arrived:
                        connections[host] = self.client_address[1]
                        arrived.notify_all()
                    release.wait(45)
        except OSError:
            pass


def processes():
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,command="], text=True, errors="replace")
    return {int(pid): {"ppid": int(parent), "command": command}
            for line in rows.splitlines() if len(parts := line.strip().split(None, 2)) == 3
            for pid, parent, command in [parts]}


def socket_owner(port, host):
    deadline = time.monotonic() + 5
    while True:
        peer = connections[host]
        output = subprocess.run(["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-Fpcn"], text=True, capture_output=True).stdout
        pid = None
        owners = set()
        for line in output.splitlines():
            if line.startswith("p"):
                pid = int(line[1:])
            elif line.startswith("n") and line[1:] == f"127.0.0.1:{peer}->127.0.0.1:{port}":
                owners.add(pid)
        if len(owners) == 1:
            return peer, owners.pop()
        if time.monotonic() > deadline:
            raise AssertionError((peer, output))
        time.sleep(0.1)


server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Proxy)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
proxy_port = server.server_address[1]
launched = []
results = {"chrome_version": plistlib.loads(Path(chrome).parents[1].joinpath("Info.plist").read_bytes())["CFBundleShortVersionString"]}
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

with tempfile.TemporaryDirectory(prefix="chrome-profiles-", dir=root / "build") as temporary:
    try:
        shared = Path(temporary) / "shared"
        shared.mkdir()
        profiles = {"Default": {"name": "Yoyo Test A"}, "Profile 1": {"name": "Yoyo Test B"}}
        (shared / "Local State").write_text(json.dumps({"profile": {"info_cache": profiles, "last_used": "Default"}}))
        for profile, attributes in profiles.items():
            (shared / profile).mkdir()
            (shared / profile / "Preferences").write_text(json.dumps({"profile": attributes}))
        for label, directory, profile in [("shared-a", "shared", "Default"), ("shared-b", "shared", "Profile 1"),
                                           ("isolated-a", "isolated-a", "Default"), ("isolated-b", "isolated-b", "Default")]:
            host = label + ".yoyo.invalid"
            user_data = str(Path(temporary) / directory)
            log = open(evidence / (label + ".stderr.log"), "w")
            proc = subprocess.Popen([chrome, "--user-data-dir=" + user_data, "--profile-directory=" + profile,
                "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
                f"--proxy-server=http://127.0.0.1:{proxy_port}", "https://" + host + "/"],
                stdout=log, stderr=log)
            launched.append((proc, log))
            deadline = time.monotonic() + 25
            with arrived:
                while host not in connections:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise RuntimeError(f"No CONNECT for {label}; see {log.name}")
                    arrived.wait(min(remaining, 1))
            peer, pid = socket_owner(proxy_port, host)
            table = processes()
            command = table[pid]["command"]
            assert "--utility-sub-type=network.mojom.NetworkService" in command, command
            path = command.split(" --", 1)[0]
            payload = {"processPath": path, "sourcePort": peer, "sourceIP": "127.0.0.1", "protocol": "HTTPS",
                       "hostname": host, "destPort": 443, "listenPort": proxy_port, "argument": "Los_Angeles"}
            request = urllib.request.Request("http://127.0.0.1:47643/v1/surge/request",
                data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
            with opener.open(request, timeout=5) as response:
                report = json.load(response)
            assert report["result"]["status"] == "socket_unique" and report["result"]["pid"] == pid, report
            ancestors = []
            current = pid
            while current in table and len(ancestors) < 10:
                ancestors.append({"pid": current, **table[current]})
                if current == proc.pid or "--type=" not in table[current]["command"]:
                    break
                current = table[current]["ppid"]
            results[label] = {"profile": profile, "user_data_directory": directory, "source_port": peer,
                              "socket_pid": pid, "ancestors": ancestors, "yoyo": report}
            print(f"{label}: profile={profile}, socket PID={pid}, parent={table[pid]['ppid']}, Yoyo PID={report['result']['pid']}", flush=True)
        for directory in ["shared", "isolated-a", "isolated-b"]:
            state = json.loads((Path(temporary) / directory / "Local State").read_text())
            results[directory + "-profiles"] = sorted(state.get("profile", {}).get("info_cache", {}))
        same = results["shared-a"]["socket_pid"] == results["shared-b"]["socket_pid"]
        different = results["isolated-a"]["socket_pid"] != results["isolated-b"]["socket_pid"]
        results["conclusions"] = {"shared_profiles_same_socket_pid": same, "isolated_directories_distinct_socket_pids": different}
        (evidence / "result.json").write_text(json.dumps(results, indent=2))
        print(json.dumps(results["conclusions"]), flush=True)
        assert different, "Separate user-data directories must use separate network processes"
    finally:
        release.set()
        # Terminate only Chrome processes with this run's unique temporary data path.
        for pid, row in processes().items():
            if temporary in row["command"] and row["command"].startswith("/Applications/Google Chrome.app/"):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for proc, log in launched:
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            log.close()
        for directory in ["shared", "isolated-a", "isolated-b"]:
            state_path = Path(temporary) / directory / "Local State"
            if state_path.exists():
                state = json.loads(state_path.read_text())
                results[directory + "-profiles"] = sorted(state.get("profile", {}).get("info_cache", {}))
        (evidence / "result.json").write_text(json.dumps(results, indent=2))
        server.shutdown()
        server.server_close()
