"""Small /proc helpers used by runner supervision and status tooling."""

from __future__ import annotations

import os
from pathlib import Path


PROC_DIR = Path("/proc")


def proc_pid_dirs() -> list[Path]:
    return [path for path in PROC_DIR.iterdir() if path.name.isdigit()]


def read_cmdline(pid: int) -> list[str]:
    try:
        data = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return []
    return [part for part in data.decode("utf-8", errors="replace").split("\x00") if part]


def read_comm(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/comm").read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def read_cwd(pid: int) -> str:
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return ""


def pid_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def cwd_under(pid: int, root: str) -> bool:
    cwd = read_cwd(pid)
    return bool(cwd) and (cwd == root or cwd.startswith(f"{root}/"))


def find_pids_by_comm(comm: str) -> list[int]:
    matches: list[int] = []
    for proc_dir in proc_pid_dirs():
        if read_comm(int(proc_dir.name)) == comm:
            matches.append(int(proc_dir.name))
    return matches


def has_child_process(root_pid: int) -> bool:
    for proc_dir in proc_pid_dirs():
        try:
            status_text = (proc_dir / "status").read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in status_text.splitlines():
            if line.startswith("PPid:"):
                _, value = line.split(":", 1)
                if value.strip() == str(root_pid):
                    return True
    return False
