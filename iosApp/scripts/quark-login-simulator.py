#!/usr/bin/env python3
"""Keep a disposable native simulator alive for assisted QR login, without exporting account data."""
import argparse
import json
import pathlib
import subprocess
import time
from importlib.machinery import SourceFileLoader

smoke = SourceFileLoader("smoke", str(pathlib.Path(__file__).with_name("smoke-simulator.py"))).load_module()
simctl = smoke.simctl
state = pathlib.Path(".quark-simulator.json")
output = pathlib.Path("quark-login-test")


def cleanup(udid):
    subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False)
    subprocess.run(["xcrun", "simctl", "delete", udid], check=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["prepare", "wait", "cleanup"])
    parser.add_argument("--app")
    args = parser.parse_args()
    output.mkdir(exist_ok=True)
    if args.mode == "prepare":
        runtimes = [r for r in json.loads(simctl("list", "runtimes", "--json"))["runtimes"]
                    if r.get("isAvailable") and ".iOS-" in r["identifier"]]
        runtime = max(runtimes, key=lambda r: tuple(int(x) for x in r["version"].split(".")))
        types = json.loads(simctl("list", "devicetypes", "--json"))["devicetypes"]
        device = next(t for t in reversed(types) if t["name"].startswith("iPhone") and "Pro Max" in t["name"])
        udid = simctl("create", "YunX assisted Quark login", device["identifier"], runtime["identifier"])
        state.write_text(json.dumps({"udid": udid}))
        simctl("boot", udid)
        simctl("bootstatus", udid, "-b", timeout=240)
        simctl("install", udid, str(pathlib.Path(args.app).resolve()))
        simctl("launch", udid, "com.yunx.app.ios", "--quark-login-test")
        time.sleep(40)
        simctl("io", udid, "screenshot", str(output / "quark-login.png"))
        print("Login screen ready; account values are masked.", flush=True)
        return
    udid = json.loads(state.read_text())["udid"]
    if args.mode == "cleanup":
        cleanup(udid)
        return
    data = pathlib.Path(simctl("get_app_container", udid, "com.yunx.app.ios", "data"))
    report = data / "Documents/quark-login-result.json"
    deadline = time.monotonic() + 600
    previous = None
    while time.monotonic() < deadline:
        if report.exists():
            result = json.loads(report.read_text())
            # Whitelist the report fields even if the application implementation changes.
            safe = {k: result[k] for k in ("stage", "hasPus", "hasPuus", "cookieCount", "fileCount") if k in result}
            if safe != previous:
                print(json.dumps(safe), flush=True)
                previous = safe
                (output / "result.json").write_text(json.dumps(safe))
            if safe.get("stage") in ("drive_read_success", "drive_read_failed"):
                if safe["stage"] != "drive_read_success":
                    raise RuntimeError("Authenticated account did not pass the drive read test")
                return
        time.sleep(3)
    raise RuntimeError("Assisted QR login timed out; see the sanitized result report")


if __name__ == "__main__":
    main()
