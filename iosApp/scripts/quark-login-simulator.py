#!/usr/bin/env python3
"""Keep a disposable native simulator alive for assisted QR login, without exporting account data."""
import argparse
import json
import pathlib
import os
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
        if os.environ.get("SIMCTL_CHILD_YUNX_QUARK_PHONE"):
            subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
                            "-out", ".quark-input-private.pem"], check=True, capture_output=True)
            subprocess.run(["openssl", "pkey", "-in", ".quark-input-private.pem", "-pubout",
                            "-out", str(output / "input-public.pem")], check=True, capture_output=True)
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
        data = pathlib.Path(simctl("get_app_container", udid, "com.yunx.app.ios", "data"))
        web_status = data / "Documents/quark-login-ui.json"
        for _ in range(20):
            time.sleep(2)
            if web_status.exists() and json.loads(web_status.read_text()).get("stage") in ("sms_sent", "sms_challenge", "sms_error"):
                break
        simctl("io", udid, "screenshot", str(output / "quark-login.png"))
        if web_status.exists():
            (output / "ui-status.json").write_text(web_status.read_text())
        print("Login screen ready; account values are masked.", flush=True)
        return
    if not state.exists() and args.mode == "cleanup":
        return
    udid = json.loads(state.read_text())["udid"]
    if args.mode == "cleanup":
        cleanup(udid)
        return
    data = pathlib.Path(simctl("get_app_container", udid, "com.yunx.app.ios", "data"))
    report = data / "Documents/quark-login-result.json"
    deadline = time.monotonic() + 600
    previous = None
    latest_asset = None
    next_control_check = 0
    release = os.environ.get("YUNX_TEST_CONTROL_RELEASE")
    while time.monotonic() < deadline:
        if release and time.monotonic() >= next_control_check:
            next_control_check = time.monotonic() + 10
            assets = json.loads(subprocess.check_output(["gh", "api", "repos/cc1477/gametool/releases/" + release + "/assets"]))
            asset = next((a for a in assets if a["name"] == "quark-login-code.enc"), None)
            if asset and asset["id"] != latest_asset:
                ciphertext = subprocess.check_output(["gh", "api", "repos/cc1477/gametool/releases/assets/" + str(asset["id"]),
                                                     "-H", "Accept: application/octet-stream"])
                decrypted = subprocess.run(["openssl", "pkeyutl", "-decrypt", "-inkey", ".quark-input-private.pem",
                    "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256"],
                    input=ciphertext, capture_output=True)
                if decrypted.returncode == 0:
                    command = json.loads(decrypted.stdout)
                    code = str(command.get("code", ""))
                    if code.isascii() and code.isdecimal() and 4 <= len(code) <= 8:
                        (data / "Documents/quark-login-command.json").write_text(json.dumps({"code": code}))
                        latest_asset = asset["id"]
                        print("Delivered encrypted SMS input to the native test.", flush=True)
        if report.exists():
            result = json.loads(report.read_text())
            # Whitelist the report fields even if the application implementation changes.
            safe = {k: result[k] for k in ("stage", "hasPus", "hasPuus", "cookieCount", "fileCount") if k in result}
            web_status = data / "Documents/quark-login-ui.json"
            if web_status.exists():
                safe["uiStage"] = json.loads(web_status.read_text()).get("stage")
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
