#!/usr/bin/env python3
"""Install and launch the CI build in a disposable iPhone simulator."""
import json
import pathlib
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
        launch = simctl("launch", udid, "com.yunx.app.ios")
        print(launch, flush=True)
        match = re.search(r":\s*(\d+)\s*$", launch)
        if not match:
            raise RuntimeError("Simulator did not return an application PID.")
        time.sleep(15)
        services = simctl("spawn", udid, "launchctl", "list")
        if not any(line.split() and line.split()[0] == match[1] for line in services.splitlines()):
            raise RuntimeError("YunX exited during the startup smoke test.")
        screenshot.parent.mkdir(parents=True, exist_ok=True)
        simctl("io", udid, "screenshot", str(screenshot))
        print(f"YunX remained running after 15 seconds; screenshot: {screenshot}")
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False)
        subprocess.run(["xcrun", "simctl", "delete", udid], check=False)


if __name__ == "__main__":
    main()
