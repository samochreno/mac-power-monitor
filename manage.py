#!/usr/bin/env python3
"""Install and inspect the two power-monitor LaunchAgents without accessing credentials."""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
HOME = Path.home()
SUPPORT = HOME / "Library/Application Support/mac-power-monitor"
LOGS = HOME / "Library/Logs/mac-power-monitor"
AGENTS = HOME / "Library/LaunchAgents"
DOMAIN = f"gui/{os.getuid()}"
LABELS = ("com.samochreno.macbook-power-monitor",
          "com.samochreno.macbook-power-sleep-listener")


def plist_path(label):
    return AGENTS / f"{label}.plist"


def render(label):
    """Substitute paths as plist values, so spaces and XML characters remain valid."""
    data = plistlib.loads((ROOT / "launchagents" / f"{label}.plist.template").read_bytes())
    replacements = {"__SUPPORT_DIR__": str(SUPPORT), "__LOG_DIR__": str(LOGS)}
    for key, value in data.items():
        if isinstance(value, str):
            for old, new in replacements.items():
                value = value.replace(old, new)
        elif isinstance(value, list):
            for old, new in replacements.items():
                value = [item.replace(old, new) for item in value]
        data[key] = value
    return plistlib.dumps(data)


def bootout(label):
    subprocess.run(["launchctl", "bootout", f"{DOMAIN}/{label}"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def details(label):
    result = subprocess.run(["launchctl", "print", f"{DOMAIN}/{label}"],
                            capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def install():
    """Build before stopping jobs; preserve runtime state and restore plists on failure."""
    if not (Path("/opt/homebrew/bin/jq").is_file() or Path("/usr/bin/jq").is_file()):
        raise RuntimeError("Install jq before installing the monitor.")
    with tempfile.TemporaryDirectory() as temporary:
        built = Path(temporary) / "sleep-listener"
        subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror",
                        "-framework", "CoreFoundation", "-framework", "IOKit",
                        str(ROOT / "sleep-listener.c"), "-o", str(built)], check=True)
        rendered = {label: render(label) for label in LABELS}
        previous = {label: plist_path(label).read_bytes() if plist_path(label).exists()
                    else None for label in LABELS}
        loaded = {label: details(label) is not None for label in LABELS}
        SUPPORT.mkdir(parents=True, exist_ok=True)
        LOGS.mkdir(parents=True, exist_ok=True)
        AGENTS.mkdir(parents=True, exist_ok=True)
        previous_programs = {}
        for name in ("monitor.zsh", "sleep-listener"):
            target = SUPPORT / name
            if target.exists():
                saved = Path(temporary) / f"previous-{name}"
                shutil.copy2(target, saved)
                previous_programs[name] = saved
        try:
            for label in LABELS:
                bootout(label)
            shutil.copy2(ROOT / "monitor.zsh", SUPPORT / "monitor.zsh")
            shutil.copy2(built, SUPPORT / "sleep-listener")
            for name in ("monitor.zsh", "sleep-listener"):
                (SUPPORT / name).chmod(0o755)
            for label, data in rendered.items():
                plist_path(label).write_bytes(data)
                plist_path(label).chmod(0o644)
                subprocess.run(["launchctl", "bootstrap", DOMAIN, str(plist_path(label))],
                               check=True)
        except Exception:
            for label in LABELS:
                bootout(label)
            for name in ("monitor.zsh", "sleep-listener"):
                if name in previous_programs:
                    shutil.copy2(previous_programs[name], SUPPORT / name)
                else:
                    (SUPPORT / name).unlink(missing_ok=True)
            for label, data in previous.items():
                if data is None:
                    plist_path(label).unlink(missing_ok=True)
                    continue
                plist_path(label).write_bytes(data)
                if loaded[label]:
                    subprocess.run(["launchctl", "bootstrap", DOMAIN, str(plist_path(label))],
                                   check=True)
            raise
    print("Installed both power-monitor services. Runtime state and Keychain were preserved.")


def status():
    for label in LABELS:
        output = details(label)
        state = "missing" if output is None else (
            "running" if "state = running" in output else "loaded/idle")
        print(f"{label}: {state}")


def audit():
    failures = []
    for label in LABELS:
        path = plist_path(label)
        if not path.exists() or plistlib.loads(path.read_bytes()) != plistlib.loads(render(label)):
            failures.append(f"Missing or drifted plist: {label}")
        output = details(label)
        if output is None:
            failures.append(f"Unloaded service: {label}")
        elif any(line.strip().startswith("last exit code =") and
                 line.partition(" = ")[2].strip().isdigit() and
                 int(line.partition(" = ")[2].strip()) != 0 for line in output.splitlines()):
            failures.append(f"Service exited unsuccessfully: {label}")
    target = SUPPORT / "monitor.zsh"
    if not target.exists() or target.read_bytes() != (ROOT / "monitor.zsh").read_bytes():
        failures.append("Missing or drifted installed monitor")
    if not os.access(SUPPORT / "sleep-listener", os.X_OK):
        failures.append("Missing compiled listener")
    if failures:
        raise RuntimeError("\n".join(failures))
    print("Audit passed: both power-monitor services match this repository.")


def uninstall():
    for label in LABELS:
        bootout(label)
        plist_path(label).unlink(missing_ok=True)
    for name in ("monitor.zsh", "sleep-listener"):
        (SUPPORT / name).unlink(missing_ok=True)
    print("Removed services and programs. State, logs, and Keychain were preserved.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("install", "status", "audit", "uninstall"))
    args = parser.parse_args()
    try:
        {"install": install, "status": status, "audit": audit,
         "uninstall": uninstall}[args.command]()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
