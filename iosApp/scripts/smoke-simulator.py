#!/usr/bin/env python3
"""Install and launch the CI build in a disposable iPhone simulator."""
import json
import pathlib
import shutil
import re
import subprocess
import sys
import time
import os
import plistlib
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class CookieWireFixture(BaseHTTPRequestHandler):
    def do_GET(self):
        fields = dict(item.strip().split("=", 1) for item in self.headers.get("Cookie", "").split(";") if "=" in item)
        expected = {"__pus": "fixture%2Fprincipal%2Bvalue%3D", "marker": "part%252Ftail",
                    "__puus": "fixture+session/value==" if self.path == "/initial" else "rotated%2B/value=="}
        payload = json.dumps({"matches": fields == expected}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        if self.path == "/initial":
            self.send_header("Set-Cookie", "__puus=rotated%2B/value==; Path=/; HttpOnly")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


def simctl(*args, timeout=180):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True, timeout=timeout).strip()


def main():
    app = pathlib.Path(sys.argv[1]).resolve()
    # Allow only local networking in this disposable simulator application, never the device IPA.
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.setdefault("NSAppTransportSecurity", {})["NSAllowsLocalNetworking"] = True
    info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    screenshot = pathlib.Path(sys.argv[2]).resolve()
    if not app.is_dir():
        raise RuntimeError(f"Built app is missing: {app}")
    runtimes = json.loads(simctl("list", "runtimes", "--json"))["runtimes"]
    devices = json.loads(simctl("list", "devices", "available", "--json"))["devices"]
    types = json.loads(simctl("list", "devicetypes", "--json"))["devicetypes"]
    candidates = []
    for runtime in runtimes:
        if not runtime.get("isAvailable") or ".iOS-" not in runtime["identifier"]:
            continue
        for device in devices.get(runtime["identifier"], []):
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                device_type = device.get("deviceTypeIdentifier") or next(
                    t["identifier"] for t in types if t["name"] == device["name"]
                )
                version = tuple(int(v) for v in runtime["version"].split("."))
                candidates.append((version, device_type, runtime["identifier"]))
    if not candidates:
        raise RuntimeError("No available iPhone simulator runtime; install one in Xcode.")
    _, device_type, runtime = max(candidates)
    udid = simctl("create", "YunX CI Smoke", device_type, runtime)
    try:
        simctl("boot", udid)
        simctl("bootstatus", udid, "-b", timeout=240)
        simctl("ui", udid, "appearance", "light")
        simctl("ui", udid, "content_size", "large")
        simctl("install", udid, str(app))
        diagnostics = screenshot.parent / "startup-diagnostics"
        diagnostics.mkdir(parents=True, exist_ok=True)
        launch = simctl("launch", "--stdout=" + str(diagnostics / "stdout.log"),
                        "--stderr=" + str(diagnostics / "stderr.log"), udid, "com.yunx.app.ios")
        print(launch, flush=True)
        match = re.search(r":\s*(\d+)\s*$", launch)
        if not match:
            raise RuntimeError("Simulator did not return an application PID.")
        time.sleep(15)
        screenshot.parent.mkdir(parents=True, exist_ok=True)
        simctl("io", udid, "screenshot", str(screenshot))
        process = subprocess.run(["ps", "-p", match[1], "-o", "comm="], capture_output=True, text=True)
        print(f"Startup process check: {process.stdout.strip() or 'not running'}", flush=True)
        if process.returncode != 0 or pathlib.Path(process.stdout.strip()).name != app.stem:
            raise RuntimeError("YunX exited during the startup smoke test.")
        print(f"YunX remained running after 15 seconds; screenshot: {screenshot}")
        # Capture system text-size changes in the active native host, then a cold launch.
        simctl("ui", udid, "content_size", "accessibility-extra-extra-extra-large")
        time.sleep(3)
        simctl("io", udid, "screenshot", str(screenshot.with_name(screenshot.stem + "-large-live.png")))
        simctl("terminate", udid, "com.yunx.app.ios")
        simctl("launch", udid, "com.yunx.app.ios")
        time.sleep(5)
        simctl("io", udid, "screenshot", str(screenshot.with_name(screenshot.stem + "-large.png")))
        simctl("ui", udid, "appearance", "dark")
        time.sleep(3)
        simctl("io", udid, "screenshot", str(screenshot.with_name(screenshot.stem + "-large-dark.png")))
        # Exercise the actual iOS exporter and share sheet using synthetic credentials only.
        simctl("terminate", udid, "com.yunx.app.ios")
        simctl("ui", udid, "appearance", "light")
        simctl("ui", udid, "content_size", "large")
        fixture = ThreadingHTTPServer(("127.0.0.1", 0), CookieWireFixture)
        threading.Thread(target=fixture.serve_forever, daemon=True).start()
        os.environ["SIMCTL_CHILD_YUNX_COOKIE_TEST_URL"] = "http://127.0.0.1:" + str(fixture.server_port) + "/"
        simctl("launch", udid, "com.yunx.app.ios", "--diagnostic-export-test")
        container = pathlib.Path(simctl("get_app_container", udid, "com.yunx.app.ios", "data"))
        marker = container / "Library/Caches/YunX/diagnostic-export-test.json"
        deadline = time.monotonic() + 40
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(1)
        result = json.loads(marker.read_text())
        simctl("io", udid, "screenshot", str(screenshot.with_name(screenshot.stem + "-diagnostic-share.png")))
        assert all(result.get(key) for key in ("exported", "sharePresented", "cookieWirePreserved")), result
        fixture.shutdown()
        fixture.server_close()
        os.environ.pop("SIMCTL_CHILD_YUNX_COOKIE_TEST_URL", None)
        import zipfile
        exported = list((container / "Documents/Downloads").glob("yunx_diagnostic_logs_*.zip"))
        assert len(exported) == 1, exported
        with zipfile.ZipFile(exported[0]) as package:
            assert package.testzip() is None
            content = "\n".join(package.read(name).decode() for name in package.namelist())
            assert "native_export_test" in content and "schema 2" in content
            assert "nativeCode=-1009" in content and "NSURLErrorDomain" in content
            assert "native_cookie_wire_verified" in content
            assert "native-secret" not in content and "second-secret" not in content
        shutil.copy2(exported[0], screenshot.parent / "YunX-diagnostic-sample.zip")
        print("Native Cookie byte preservation, rotation, ZIP integrity, redaction and UIKit share sheet passed.", flush=True)
    except Exception:
        diagnostics = screenshot.parent / "startup-diagnostics"
        diagnostics.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            ["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "3m", "--style", "compact",
             "--predicate", 'process == "YunX" OR eventMessage CONTAINS[c] "com.yunx.app.ios" OR process == "ReportCrash"'], capture_output=True, text=True, timeout=60
        )
        (diagnostics / "YunX.log").write_text(result.stdout + result.stderr)
        print(result.stdout[-16000:], flush=True)
        for stream in ("stdout.log", "stderr.log"):
            path = diagnostics / stream
            if path.exists():
                print(f"{stream}:\n{path.read_text(errors='replace')[-16000:]}", flush=True)
        device_data = pathlib.Path.home() / "Library/Developer/CoreSimulator/Devices" / udid / "data"
        reports = list((pathlib.Path.home() / "Library/Logs/DiagnosticReports").glob("YunX*"))
        reports += list((device_data / "Library/Logs").rglob("*YunX*"))
        for report in reports:
            if report.is_file():
                shutil.copy2(report, diagnostics / report.name)
                print(f"Saved crash report: {report.name}", flush=True)
        # Relaunch only for diagnosis; a successful retry never passes the smoke test.
        try:
            launch = simctl("launch", "--wait-for-debugger", udid, "com.yunx.app.ios")
            debug_pid = re.search(r":\s*(\d+)\s*$", launch)[1]
            result = subprocess.run(
                ["xcrun", "lldb", "--batch", "-p", debug_pid, "-o", "continue",
                 "-k", "thread backtrace all", "-k", "quit"],
                capture_output=True, text=True, timeout=90
            )
            (diagnostics / "lldb.log").write_text(result.stdout + result.stderr)
            print(result.stdout[-24000:] + result.stderr[-4000:], flush=True)
        except Exception as debug_error:
            print(f"Debugger diagnostic failed: {debug_error}", flush=True)
        raise
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False)
        subprocess.run(["xcrun", "simctl", "delete", udid], check=False)


if __name__ == "__main__":
    main()
