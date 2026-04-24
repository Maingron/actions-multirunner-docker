#!/usr/bin/env python3
"""Pool manager for a single runner config entry."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time

from shared.proc_utils import cwd_under, find_pids_by_comm
from shared.runtime_helpers import singleton_pool


def env_int(name: str, default: int) -> int:
    try:
        return max(int(os.environ.get(name, str(default))), 0)
    except ValueError:
        return default


def log(base_title: str, message: str, repo_url: str = "") -> None:
    prefix = f"[pool:{base_title}"
    if repo_url:
        # Extract owner/repo from full URL (e.g., https://github.com/owner/repo -> owner/repo)
        if "github.com/" in repo_url:
            repo_part = repo_url.split("github.com/", 1)[1].rstrip("/").rstrip(".git")
        else:
            repo_part = repo_url
        prefix += f" ({repo_part})"
    prefix += "] "
    print(f"{prefix}{message}", flush=True)


def worker_active_in_dir(directory: str) -> bool:
    return any(cwd_under(pid, directory) for pid in find_pids_by_comm("Runner.Worker"))


def instance_title(base_title: str, idx: int, singleton: bool) -> str:
    return base_title if singleton else f"{base_title}-{idx:02d}"


def instance_dir(base_workdir: str, idx: int, singleton: bool) -> str:
    return base_workdir if singleton else f"{base_workdir}-{idx:02d}"


def spawn_instance(base_title: str, repo_url: str, static_token: str, base_workdir: str, singleton: bool, pool_max: int, pids: dict[int, subprocess.Popen[str]], dirs: dict[int, str], spawned_at: dict[int, float]) -> bool:
    free_idx = next((idx for idx in range(1, pool_max + 1) if idx not in pids), 0)
    if not free_idx:
        return False
    title = instance_title(base_title, free_idx, singleton)
    directory = instance_dir(base_workdir, free_idx, singleton)
    log(base_title, f"spawning instance {free_idx} (title={title})", repo_url)
    proc = subprocess.Popen(["python3", "/usr/local/bin/start-runner.py", title, repo_url, static_token, directory], text=True)
    pids[free_idx] = proc
    dirs[free_idx] = directory
    spawned_at[free_idx] = time.monotonic()
    return True


def reap_dead(base_title: str, repo_url: str, pids: dict[int, subprocess.Popen[str]], dirs: dict[int, str], spawned_at: dict[int, float], last_busy_at: dict[int, float], phantom_busy_until: list[float], demand_cooldown: int) -> None:
    for idx in tuple(pids):
        proc = pids[idx]
        if proc.poll() is None:
            continue
        proc.wait(timeout=0)
        log(base_title, f"instance {idx} exited", repo_url)
        # If this instance was recently busy, preserve its demand signal for
        # a short cooldown window. Without this, an ephemeral worker that
        # finishes between ticks takes its busy signal with it, causing the
        # reconcile loop to drop desired capacity mid-workload.
        last = last_busy_at.get(idx, 0.0)
        if demand_cooldown > 0 and last > 0.0:
            elapsed = time.monotonic() - last
            remaining = demand_cooldown - elapsed
            if remaining > 0:
                phantom_busy_until.append(time.monotonic() + remaining)
        del pids[idx]
        dirs.pop(idx, None)
        spawned_at.pop(idx, None)
        last_busy_at.pop(idx, None)


def shutdown(base_title: str, repo_url: str, pids: dict[int, subprocess.Popen[str]]) -> None:
    log(base_title, f"shutting down pool ({len(pids)} instance(s))", repo_url)
    for proc in pids.values():
        if proc.poll() is None:
            proc.terminate()
    for proc in pids.values():
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()


def fill_pool(base_title: str, repo_url: str, static_token: str, base_workdir: str, singleton: bool, count: int, pool_max: int, pids: dict[int, subprocess.Popen[str]], dirs: dict[int, str], spawned_at: dict[int, float]) -> None:
    for _ in range(count):
        if not spawn_instance(base_title, repo_url, static_token, base_workdir, singleton, pool_max, pids, dirs, spawned_at):
            return  # repo_url passed to spawn_instance which logs it


def current_pool_state(dirs: dict[int, str], last_busy_at: dict[int, float], demand_cooldown: int) -> tuple[int, list[int]]:
    """Classify live instances as busy or idle.

    An instance counts as busy if it has a Runner.Worker under its workdir OR
    it was observed busy within the demand-cooldown window. The cooldown
    smooths over the gap between "worker exits" and "ephemeral supervisor
    respawns a fresh listener", preventing a peer instance from being drained
    during an active workload.
    """
    now = time.monotonic()
    busy = 0
    idle_idxs: list[int] = []
    for idx, directory in dirs.items():
        active = worker_active_in_dir(directory)
        if active:
            last_busy_at[idx] = now
            busy += 1
            continue
        last = last_busy_at.get(idx, 0.0)
        if demand_cooldown > 0 and last > 0.0 and now - last < demand_cooldown:
            busy += 1
            continue
        idle_idxs.append(idx)
    return busy, idle_idxs


def expire_phantoms(phantom_busy_until: list[float]) -> int:
    now = time.monotonic()
    phantom_busy_until[:] = [until for until in phantom_busy_until if until > now]
    return len(phantom_busy_until)


def reconcile_pool(base_title: str, repo_url: str, static_token: str, base_workdir: str, singleton: bool, pool_min: int, pool_max: int, pool_headroom: int, scale_down_grace: int, demand_cooldown: int, pids: dict[int, subprocess.Popen[str]], dirs: dict[int, str], spawned_at: dict[int, float], last_busy_at: dict[int, float], phantom_busy_until: list[float], verbose: bool) -> None:
    busy, idle_idxs = current_pool_state(dirs, last_busy_at, demand_cooldown)
    phantoms = expire_phantoms(phantom_busy_until)
    effective_busy = busy + phantoms
    alive = len(pids)
    desired = max(pool_min, min(pool_max, effective_busy + pool_headroom))
    if verbose:
        log(base_title, f"tick: busy={busy} phantom={phantoms} idle={alive - busy} alive={alive} desired={desired} (min={pool_min} max={pool_max} headroom={pool_headroom})", repo_url)
    if alive < desired:
        need = desired - alive
        log(base_title, f"scale up: busy={busy} phantom={phantoms} alive={alive} -> spawning {need} (desired={desired})", repo_url)
        fill_pool(base_title, repo_url, static_token, base_workdir, singleton, need, pool_max, pids, dirs, spawned_at)
        return
    if alive <= desired:
        return
    excess = alive - desired
    now = time.monotonic()
    # Only drain idle instances that have been alive longer than the grace
    # period. Freshly-spawned instances commonly appear idle for a second or
    # two while Runner.Listener boots; terminating them immediately causes
    # needless churn and delays job pickup.
    drainable = [idx for idx in idle_idxs if now - spawned_at.get(idx, 0.0) >= scale_down_grace]
    if verbose and len(drainable) < len(idle_idxs):
        holding = len(idle_idxs) - len(drainable)
        log(base_title, f"scale down: holding {holding} idle instance(s) within {scale_down_grace}s grace", repo_url)
    for idx in drainable:
        if excess <= 0:
            break
        log(base_title, f"scale down: draining idle instance {idx} (pid={pids[idx].pid})", repo_url)
        pids[idx].terminate()
        excess -= 1


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: pool-manager.py <title> <repo_url> <token> <workdir>", file=sys.stderr)
        return 2

    base_title, repo_url, static_token, base_workdir = sys.argv[1:5]
    pool_min = max(env_int("POOL_MIN", 1), 1)
    pool_max = max(env_int("POOL_MAX", pool_min), pool_min)
    pool_headroom = env_int("POOL_HEADROOM", 0)
    scale_down_grace = env_int("POOL_SCALE_DOWN_GRACE", 10)
    demand_cooldown = env_int("POOL_DEMAND_COOLDOWN", 30)
    poll_interval = max(env_int("POOL_POLL_INTERVAL", 5), 1)
    verbose = os.environ.get("POOL_VERBOSE", "0") == "1"
    singleton = singleton_pool(pool_min, pool_max, pool_headroom)

    pids: dict[int, subprocess.Popen[str]] = {}
    dirs: dict[int, str] = {}
    spawned_at: dict[int, float] = {}
    last_busy_at: dict[int, float] = {}
    phantom_busy_until: list[float] = []
    stopping = False

    def handle_signal(signum: int, frame: object) -> None:
        nonlocal stopping
        stopping = True
        shutdown(base_title, repo_url, pids)
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    log(base_title, f"starting pool (min={pool_min} max={pool_max} headroom={pool_headroom} scale_down_grace={scale_down_grace}s demand_cooldown={demand_cooldown}s)", repo_url)
    fill_pool(base_title, repo_url, static_token, base_workdir, singleton, pool_min, pool_max, pids, dirs, spawned_at)

    while not stopping:
        time.sleep(poll_interval)
        reap_dead(base_title, repo_url, pids, dirs, spawned_at, last_busy_at, phantom_busy_until, demand_cooldown)

        reconcile_pool(base_title, repo_url, static_token, base_workdir, singleton, pool_min, pool_max, pool_headroom, scale_down_grace, demand_cooldown, pids, dirs, spawned_at, last_busy_at, phantom_busy_until, verbose)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
