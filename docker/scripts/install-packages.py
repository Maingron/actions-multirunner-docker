#!/usr/bin/env python3
"""Autodetect the container's package manager and install packages."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys


def main() -> int:
    packages = sys.argv[1:]
    if not packages:
        return 0

    managers = ["apt-get", "dnf", "yum", "apk", "zypper", "pacman"]
    manager = next((name for name in managers if shutil.which(name)), "")
    if not manager:
        print(
            "install-packages: no supported package manager found (tried apt-get, dnf, yum, apk, zypper, pacman)",
            file=sys.stderr,
        )
        return 1

    print(f"install-packages: using {manager} to install: {' '.join(packages)}")
    commands: dict[str, list[str]] = {
        "apt-get": [manager, "install", "-y", "--no-install-recommends", *packages],
        "dnf": [manager, "install", "-y", *packages],
        "yum": [manager, "install", "-y", *packages],
        "apk": [manager, "add", "--no-cache", *packages],
        "zypper": [manager, "--non-interactive", "install", "--no-recommends", *packages],
        "pacman": [manager, "-Sy", "--noconfirm", "--needed", *packages],
    }

    if manager == "apt-get":
        env = os.environ.copy()
        env["DEBIAN_FRONTEND"] = "noninteractive"
        if subprocess.run([manager, "update"], env=env, check=False).returncode != 0:
            return 1
        if subprocess.run(commands[manager], env=env, check=False).returncode != 0:
            return 1
        shutil.rmtree("/var/lib/apt/lists", ignore_errors=True)
        os.makedirs("/var/lib/apt/lists", exist_ok=True)
        return 0

    if subprocess.run(commands[manager], check=False).returncode != 0:
        return 1

    cleanup: dict[str, list[str]] = {
        "dnf": [manager, "clean", "all"],
        "yum": [manager, "clean", "all"],
        "zypper": [manager, "clean", "--all"],
        "pacman": [manager, "-Scc", "--noconfirm"],
    }
    if manager in cleanup:
        subprocess.run(cleanup[manager], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
