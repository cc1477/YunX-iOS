#!/usr/bin/env python3
"""Install and launch the CI build in a disposable iPhone simulator."""
import json
import pathlib
import shutil
import re
import subprocess
import sys
import time


def simctl(*args, timeout=180):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True, timeout=timeout).strip()


def main():
    app = pathlib.Path(sys.argv[1]).resolve()
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
                 "-o", "thread backtrace all", "-o", "quit"],
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
