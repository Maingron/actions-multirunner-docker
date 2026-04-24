#!/usr/bin/env python3
"""Pretty runner status dashboard."""

from __future__ import annotations

import io
import json
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
COMPOSE_FILE = REPO_ROOT / "docker" / "docker-compose.yml"

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


@dataclass(frozen=True)
class Colors:
    bold: str    = "\x1b[1m"
    dim: str     = "\x1b[2m"
    red: str     = "\x1b[31m"
    green: str   = "\x1b[32m"
    yellow: str  = "\x1b[33m"
    cyan: str    = "\x1b[36m"
    magenta: str = "\x1b[35m"
    grey: str    = "\x1b[90m"
    reset: str   = "\x1b[0m"


NO_COLOR = Colors("", "", "", "", "", "", "", "", "")
ANSI     = Colors()


# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------

def _visible_len(s: str) -> int:
    return len(_ANSI_RE.sub("", s))


def _trunc(s: str, max_w: int) -> str:
    plain = _ANSI_RE.sub("", s)
    if len(plain) <= max_w:
        return s
    return plain[:max_w - 1] + "…"


def _pad_r(s: str, width: int) -> str:
    return s + " " * max(0, width - _visible_len(s))


def _fmt_duration(seconds: int) -> str:
    s = max(0, seconds)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m{s % 60}s"
    if s < 86400:
        return f"{s // 3600}h{(s % 3600) // 60}m"
    return f"{s // 86400}d{(s % 86400) // 3600}h"


def _uptime_str(started_at: str) -> str:
    if not started_at or started_at.startswith("0001"):
        return ""
    try:
        dt = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
        return _fmt_duration(int((datetime.now(timezone.utc) - dt).total_seconds()))
    except (ValueError, OverflowError):
        return ""


def _repo_short(url: str) -> str:
    s = url.split("://", 1)[-1]
    parts = s.split("/")
    s = "/".join(parts[1:]) if len(parts) > 1 else s
    return s.rstrip("/").removesuffix(".git")


# ---------------------------------------------------------------------------
# Subprocess helpers
# ---------------------------------------------------------------------------

def _run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=REPO_ROOT,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def ensure_compose_file() -> None:
    if COMPOSE_FILE.is_file():
        return
    proc = _run(["python3", "docker/render.py"])
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip() or "status: failed to generate docker-compose.yml")


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def _parse_args(argv: list[str]) -> tuple[str, bool, int]:
    mode = "pretty"
    watch = False
    interval = 3
    idx = 0
    while idx < len(argv):
        arg = argv[idx]
        if arg == "--json":
            mode = "json"
        elif arg == "--plain":
            mode = "plain"
        elif arg in {"--watch", "-w"}:
            watch = True
            if idx + 1 < len(argv) and argv[idx + 1].isdigit():
                interval = int(argv[idx + 1])
                idx += 1
        elif arg in {"-h", "--help"}:
            print("Usage: ./start.sh status [--watch [N]] [--json|--plain]")
            raise SystemExit(0)
        else:
            print(f"status: unknown argument: {arg}", file=sys.stderr)
            raise SystemExit(2)
        idx += 1
    return mode, watch, max(interval, 1)


# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------

def _load_services() -> list[dict[str, str]]:
    proc = _run(["docker", "compose", "-f", str(COMPOSE_FILE), "config", "--format", "json"])
    payload = json.loads(proc.stdout or "{}") if proc.returncode == 0 else {}
    services = payload.get("services") if isinstance(payload, dict) else {}
    out: list[dict[str, str]] = []
    if not isinstance(services, dict):
        return out
    for name, spec in services.items():
        if not isinstance(spec, dict):
            continue
        env = spec.get("environment") if isinstance(spec.get("environment"), dict) else {}
        out.append({
            "service":   name,
            "container": str(spec.get("container_name") or name),
            "flavor":    str(env.get("RUNNER_IMAGE_FLAVOR") or ""),
        })
    return out


def _inspect_container(name: str) -> dict[str, Any]:
    proc = _run([
        "docker", "inspect",
        "--format", "{{.State.Status}}|{{.State.StartedAt}}|{{.RestartCount}}",
        name,
    ])
    if proc.returncode != 0 or not proc.stdout.strip():
        return {"state": "missing", "started_at": "", "restarts": 0}
    parts = (proc.stdout.strip().split("|", 2) + ["", "", "0"])[:3]
    return {"state": parts[0], "started_at": parts[1], "restarts": int(parts[2] or "0")}


def _container_runners(name: str) -> list[dict[str, Any]]:
    proc = _run(["docker", "exec", name, "python3", "/usr/local/bin/status.py"])
    if proc.returncode != 0:
        return []
    out: list[dict[str, Any]] = []
    for line in proc.stdout.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            out.append(value)
    return out


def collect_status() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for svc in _load_services():
        info    = _inspect_container(svc["container"])
        runners = _container_runners(svc["container"]) if info["state"] == "running" else []
        rows.append({
            "container":  svc["container"],
            "service":    svc["service"],
            "flavor":     svc["flavor"],
            "state":      info["state"],
            "started_at": info["started_at"],
            "restarts":   info["restarts"],
            "runners":    runners,
        })
    return rows


# ---------------------------------------------------------------------------
# Classification helpers
# ---------------------------------------------------------------------------

def _classify_runner(runner: dict[str, Any], c: Colors) -> tuple[str, str]:
    """Return (kind, colored_label). kind = idle | busy | down | starting."""
    sup      = runner.get("sup_pid")
    worker   = bool(runner.get("worker"))
    listener = bool(runner.get("listener"))
    api      = runner.get("api")
    api_busy = 0
    if isinstance(api, dict) and api.get("reachable"):
        api_busy = sum(1 for m in api.get("matches", []) if m.get("busy"))

    if sup is None:
        return "down",     f"{c.red}○ down{c.reset}"
    if worker or api_busy > 0:
        return "busy",     f"{c.cyan}● busy{c.reset}"
    if listener:
        return "idle",     f"{c.green}● idle{c.reset}"
    return "starting",     f"{c.yellow}◐ start{c.reset}"


def _fmt_api_cell(runner: dict[str, Any], c: Colors) -> str:
    api = runner.get("api")
    if api is None:
        return f"{c.dim}—{c.reset}"
    if not isinstance(api, dict) or not api.get("reachable"):
        return f"{c.red}unreachable{c.reset}"
    matches = api.get("matches", [])
    if not matches:
        return f"{c.dim}no regs{c.reset}"
    busy_n   = sum(1 for m in matches if m.get("busy"))
    online_n = sum(1 for m in matches if m.get("status") == "online")
    if busy_n > 0:
        return f"{c.cyan}busy{c.reset}"
    if online_n > 0:
        return f"{c.green}online{c.reset}"
    return f"{c.yellow}offline{c.reset}"


# ---------------------------------------------------------------------------
# Dashboard renderer  (container header → indented runner rows)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Column layout helper
# ---------------------------------------------------------------------------

def _col_widths(cols: int) -> tuple[int, int]:
    """Return (w_title, w_repo) based on terminal width."""
    if cols >= 130:
        w_title = 40
    elif cols >= 110:
        w_title = 32
    else:
        w_title = 24

    if cols >= 160:
        w_repo = 36
    elif cols >= 140:
        w_repo = 30
    elif cols >= 120:
        w_repo = 24
    else:
        w_repo = 0

    return w_title, w_repo


# ---------------------------------------------------------------------------
# Per-container and per-runner row renderers
# ---------------------------------------------------------------------------

def _container_dot_label(state: str, c: Colors) -> tuple[str, str, bool]:
    """Return (dot, label, is_up)."""
    if state == "running":
        return f"{c.green}●{c.reset}", f"{c.green}{c.bold}UP{c.reset}", True
    if state == "missing":
        return f"{c.dim}○{c.reset}", f"{c.dim}NOT CREATED{c.reset}", False
    if state in ("exited", "dead"):
        return f"{c.red}○{c.reset}", f"{c.red}{c.bold}DOWN{c.reset}", False
    if state == "restarting":
        return f"{c.yellow}◐{c.reset}", f"{c.yellow}{c.bold}RESTARTING{c.reset}", False
    return f"{c.yellow}○{c.reset}", f"{c.yellow}{c.bold}{state.upper()}{c.reset}", False


def _write_container_row(
    out: io.StringIO,
    row: dict[str, Any],
    dot: str,
    label: str,
    w_title: int,
    w_status: int,
    c: Colors,
) -> None:
    uptime   = _uptime_str(row["started_at"])
    restarts = row["restarts"]
    cname_disp = _trunc(f"{c.bold}{row['container']}{c.reset}", w_title + 1)
    out.write(f"\n  {dot} ")
    out.write(_pad_r(cname_disp, w_title + 2))
    out.write(_pad_r(label, w_status))
    if uptime:
        out.write(f"{c.dim}{uptime:<12}{c.reset}")
    if restarts and row["state"] == "running":
        out.write(f" {c.yellow}{restarts} restarts{c.reset}")
    out.write("\n")


def _write_runner_row(
    out: io.StringIO,
    runner: dict[str, Any],
    w_title: int,
    w_status: int,
    w_api: int,
    w_job: int,
    w_repo: int,
    c: Colors,
) -> str:
    """Write one runner row and return the runner kind (idle/busy/down/starting)."""
    title  = str(runner.get("title") or "")
    worker = bool(runner.get("worker"))
    repo   = _repo_short(str(runner.get("repo_url") or ""))

    kind, status_txt = _classify_runner(runner, c)
    job_txt    = f"{c.cyan}● running{c.reset}" if worker else f"{c.dim}—{c.reset}"
    title_disp = _trunc(f"{c.bold}{title}{c.reset}", w_title - 1)
    api_cell   = _fmt_api_cell(runner, c)

    out.write("      ")
    out.write(_pad_r(title_disp, w_title))
    out.write(_pad_r(status_txt, w_status))
    out.write(_pad_r(api_cell,   w_api))
    out.write(_pad_r(job_txt,    w_job))
    if w_repo > 0:
        out.write(_pad_r(_trunc(f"{c.dim}{repo}{c.reset}", w_repo - 1), w_repo))
    out.write("\n")
    return kind


def _process_runners(
    out: io.StringIO,
    runners: list[dict[str, Any]],
    w_title: int,
    w_status: int,
    w_api: int,
    w_job: int,
    w_repo: int,
    c: Colors,
) -> tuple[int, int, int, int]:
    """Write all runner rows; return (idle, busy, down, starting) counts."""
    idle = busy = down = start = 0
    for runner in runners:
        kind = _write_runner_row(out, runner, w_title, w_status, w_api, w_job, w_repo, c)
        if kind == "idle":
            idle  += 1
        elif kind == "busy":
            busy  += 1
        elif kind == "down":
            down  += 1
        else:
            start += 1
    return idle, busy, down, start


# ---------------------------------------------------------------------------
# Dashboard renderer  (container header → indented runner rows)
# ---------------------------------------------------------------------------

def _render_dashboard(
    rows: list[dict[str, Any]],
    *,
    c: Colors,
    watch: bool,
    interval: int,
) -> str:
    out  = io.StringIO()
    cols = shutil.get_terminal_size((100, 30)).columns
    bar_w = min(max(cols - 4, 40), 96)
    w_title, w_repo = _col_widths(cols)
    w_status = 10
    w_api    = 12
    w_job    = 10

    # Header
    now_str = time.strftime("%Y-%m-%d %H:%M:%S %Z")
    out.write("\n")
    out.write(f"  {c.bold}{c.magenta}github-multirunner{c.reset}  {c.dim}· {now_str}{c.reset}")
    if watch:
        out.write(f"  {c.dim}(refresh {interval}s · Ctrl-C to exit){c.reset}")
    out.write(f"\n  {c.grey}{'━' * bar_w}{c.reset}\n")

    if not rows:
        out.write(f"\n  {c.yellow}No containers defined. Run ./start.sh to build + start.{c.reset}\n\n")
        return out.getvalue()

    container_up  = 0
    total_runners = 0
    total_idle    = 0
    total_busy    = 0
    total_down    = 0
    total_start   = 0

    for row in rows:
        dot, label, is_up = _container_dot_label(row["state"], c)
        if is_up:
            container_up += 1
        _write_container_row(out, row, dot, label, w_title, w_status, c)

        if row["state"] != "running" or not row["runners"]:
            continue

        idle, busy, down, start = _process_runners(
            out, row["runners"], w_title, w_status, w_api, w_job, w_repo, c
        )
        total_runners += idle + busy + down + start
        total_idle    += idle
        total_busy    += busy
        total_down    += down
        total_start   += start

    # Footer
    out.write(f"\n  {c.grey}{'━' * bar_w}{c.reset}\n")
    out.write(
        f"  {c.bold}{total_runners} runners{c.reset}"
        f"  {c.green}{total_idle} idle{c.reset}"
        f"  {c.cyan}{total_busy} busy{c.reset}"
        f"  {c.yellow}{total_start} starting{c.reset}"
        f"  {c.red}{total_down} down{c.reset}"
        f"   {c.dim}· {container_up}/{len(rows)} containers up{c.reset}\n\n"
    )
    return out.getvalue()


# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------

def _print_json(rows: list[dict[str, Any]]) -> None:
    for row in rows:
        if row["runners"]:
            for runner in row["runners"]:
                merged = dict(runner)
                merged.update({
                    "container":       row["container"],
                    "service":         row["service"],
                    "container_state": row["state"],
                    "restarts":        row["restarts"],
                })
                print(json.dumps(merged, separators=(",", ":")))
        else:
            print(json.dumps({
                "container": row["container"],
                "service":   row["service"],
                "image":     row["flavor"],
                "state":     row["state"],
                "restarts":  row["restarts"],
                "runner":    None,
            }, separators=(",", ":")))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    mode, watch, interval = _parse_args(sys.argv[1:])
    ensure_compose_file()

    if mode == "json":
        _print_json(collect_status())
        return

    c      = ANSI if (mode == "pretty" and sys.stdout.isatty()) else NO_COLOR
    is_tty = sys.stdout.isatty()

    if watch and is_tty:
        sys.stdout.write("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H")
        sys.stdout.flush()

        def _exit_watch(code: int) -> None:
            sys.stdout.write("\x1b[?25h\x1b[?1049l")
            sys.stdout.flush()
            sys.exit(code)

        signal.signal(signal.SIGTERM, lambda _s, _f: _exit_watch(143))
        signal.signal(signal.SIGINT,  lambda _s, _f: _exit_watch(130))

    try:
        while True:
            frame = _render_dashboard(
                collect_status(),
                c=c,
                watch=watch,
                interval=interval,
            )
            if watch and is_tty:
                sys.stdout.write("\x1b[H\x1b[J")
            sys.stdout.write(frame)
            sys.stdout.flush()
            if not watch:
                break
            time.sleep(interval)
    finally:
        if watch and is_tty:
            sys.stdout.write("\x1b[?25h\x1b[?1049l")
            sys.stdout.flush()


if __name__ == "__main__":
    main()

    main()
