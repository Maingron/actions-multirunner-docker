#!/usr/bin/env python3
"""Supervise one GitHub Actions runner."""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from shared.github_api import delete_runner, fetch_jit_config, fetch_registration_token, split_csv_labels
from shared.proc_utils import cwd_under, find_pids_by_comm, has_child_process
from shared.runner_store_lib import add_record, remove_record


class RunnerSupervisor:
    def __init__(self, title: str, repo_url: str, static_token: str, runner_dir: str) -> None:
        self.title = title
        self.repo_url = repo_url
        self.static_token = static_token
        self.runner_dir = runner_dir
        self.template_dir = os.environ.get("TEMPLATE_DIR", "/home/github-runner/.template")
        self.restart_delay = max(int(os.environ.get("RUNNER_RESTART_DELAY", "5") or "5"), 1)
        self.ephemeral = os.environ.get("EPHEMERAL", "1") == "1"
        self.pat = os.environ.get("PAT", "")
        self.runner_labels = os.environ.get("RUNNER_LABELS", "self-hosted,linux,x64")
        self.runner_group_id = int(os.environ.get("RUNNER_GROUP_ID", "1") or "1")
        self.idle_regeneration = max(int(os.environ.get("IDLE_REGENERATION", "0") or "0"), 0)
        self.idle_poll_interval = max(int(os.environ.get("IDLE_POLL_INTERVAL", "10") or "10"), 1)
        self.watchdog_enabled = os.environ.get("WATCHDOG_ENABLED", "0") == "1"
        self.watchdog_interval = max(int(os.environ.get("WATCHDOG_INTERVAL", "0") or "0"), 0)
        self.watchdog_grace = max(int(os.environ.get("WATCHDOG_GRACE", "60") or "60"), 0)
        self.watchdog_misses = max(int(os.environ.get("WATCHDOG_MISSES", "2") or "2"), 1)
        self.persistent_storage_path = os.environ.get("PERSISTENT_STORAGE_PATH", "")
        self.persistent_storage_ttl = max(int(os.environ.get("PERSISTENT_STORAGE_TTL", "0") or "0"), 0)
        self.run_proc: subprocess.Popen[str] | None = None
        self.current_runner_id = ""
        self.jit_id_file = ""

    def log(self, message: str) -> None:
        # Extract owner/repo from full URL (e.g., https://github.com/owner/repo -> owner/repo)
        repo_part = ""
        if "github.com/" in self.repo_url:
            repo_part = self.repo_url.split("github.com/", 1)[1].rstrip("/").rstrip(".git")
        else:
            repo_part = self.repo_url
        prefix = f"[{self.title} ({repo_part})]" if repo_part else f"[{self.title}]"
        print(f"{prefix} {message}", flush=True)

    def sweep_persistent_storage(self) -> None:
        if not self.persistent_storage_path:
            return
        root = Path(self.persistent_storage_path)
        root.mkdir(parents=True, exist_ok=True)
        if self.persistent_storage_ttl <= 0:
            return
        cutoff = time.time() - self.persistent_storage_ttl
        for path in sorted(root.rglob("*"), reverse=True):
            try:
                if path.stat().st_mtime > cutoff:
                    continue
                if path.is_dir():
                    path.rmdir()
                else:
                    path.unlink()
            except OSError:
                continue

    def worker_active(self) -> bool:
        return any(cwd_under(pid, self.runner_dir) for pid in find_pids_by_comm("Runner.Worker"))

    def materialise(self) -> None:
        shutil.rmtree(self.runner_dir, ignore_errors=True)
        Path(self.runner_dir).parent.mkdir(parents=True, exist_ok=True)
        proc = subprocess.run(["cp", "-al", self.template_dir, self.runner_dir], check=False)
        if proc.returncode != 0:
            print(f"start-runner: failed to hardlink template ({self.template_dir}) into {self.runner_dir}", file=sys.stderr)
            print(f"start-runner: template must live on the same filesystem as {self.runner_dir}", file=sys.stderr)
            raise SystemExit(1)

    def registration_token(self) -> str:
        if self.pat:
            _, response = fetch_registration_token(self.repo_url, self.pat)
            if response.status not in {200, 201}:
                raise RuntimeError("could not obtain registration token")
            payload = response.json() or {}
            token = str(payload.get("token") or "")
            if not token:
                raise RuntimeError("empty registration token")
            return token
        return self.static_token

    def deregister_current_runner(self) -> None:
        if self.current_runner_id and self.pat:
            self.log(f"deregistering JIT runner id={self.current_runner_id}")
            delete_runner(self.repo_url, self.pat, self.current_runner_id)
            remove_record(self.current_runner_id)
        self.current_runner_id = ""
        if self.jit_id_file:
            try:
                os.unlink(self.jit_id_file)
            except OSError:
                pass

    def stop_child(self, _signum: int, _frame: object) -> None:
        if self.run_proc and self.run_proc.poll() is None:
            self.run_proc.terminate()
            try:
                self.run_proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.run_proc.kill()
        if self.ephemeral:
            self.deregister_current_runner()
        elif Path(self.runner_dir).is_dir():
            try:
                token = self.registration_token()
            except RuntimeError:
                token = ""
            if token:
                subprocess.run(["./config.sh", "remove", "--token", token], cwd=self.runner_dir, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise SystemExit(0)

    def watch_sleep_interval(self) -> int:
        candidates = [value for value in (self.idle_poll_interval if self.idle_regeneration > 0 else 0, self.watchdog_interval) if value > 0]
        return max(1, min(candidates) if candidates else 1)

    def idle_rotation_needed(self, idle_last_active: float) -> bool:
        return self.idle_regeneration > 0 and time.time() - idle_last_active >= self.idle_regeneration

    def watchdog_state(self, start_ts: float, misses: int) -> tuple[int, bool]:
        if not self.watchdog_enabled or self.watchdog_interval <= 0:
            return misses, False
        if time.time() - start_ts < self.watchdog_grace:
            return misses, False
        if has_child_process(self.run_proc.pid) or self.worker_active():
            return 0, False
        misses += 1
        return misses, misses >= self.watchdog_misses

    def wait_with_watchdogs(self) -> None:
        if not self.run_proc:
            return
        start_ts = time.time()
        idle_last_active = start_ts
        misses = 0
        while self.run_proc.poll() is None:
            time.sleep(self.watch_sleep_interval())
            if self.worker_active():
                idle_last_active = time.time()
                misses = 0
            if self.idle_rotation_needed(idle_last_active):
                self.log(f"idle for {self.idle_regeneration}s, rotating runner")
                self.run_proc.terminate()
                break
            misses, triggered = self.watchdog_state(start_ts, misses)
            if triggered:
                self.log(f"watchdog: run.sh has no children for {misses * self.watchdog_interval}s, restarting")
                self.run_proc.terminate()
                break
        self.run_proc.wait()

    def create_jit_id_file(self) -> str:
        handle = tempfile.NamedTemporaryFile(prefix="jit-runner-", delete=False)
        handle.close()
        return handle.name

    def run_ephemeral(self) -> int:
        if not self.pat:
            self.log("ephemeral mode requires a PAT (config.yml 'pat:' or $GITHUB_PAT)")
            return 1
        self.jit_id_file = self.create_jit_id_file()
        iteration = 0
        while True:
            iteration += 1
            runner_name = f"{self.title}-{int(time.time())}-{iteration}"
            self.log(f"minting JIT config for {runner_name}")
            _, response = fetch_jit_config(self.repo_url, self.pat, runner_name, split_csv_labels(self.runner_labels), self.runner_group_id)
            if response.status not in {200, 201}:
                self.log(f"jitconfig request failed; retrying in {self.restart_delay}s")
                time.sleep(self.restart_delay)
                continue
            payload = response.json() or {}
            jit_config = str(payload.get("encoded_jit_config") or "")
            self.current_runner_id = str(((payload.get("runner") or {}).get("id") or "")).strip()
            if self.current_runner_id:
                add_record(self.repo_url, int(self.current_runner_id), runner_name, flavor=os.environ.get("RUNNER_IMAGE_FLAVOR", ""))

            self.materialise()
            self.sweep_persistent_storage()
            env = os.environ.copy()
            env["RUNNER_PERSISTENT_STORAGE"] = self.persistent_storage_path
            self.log("running (ephemeral, one job then exit)")
            self.run_proc = subprocess.Popen(["./run.sh", "--jitconfig", jit_config], cwd=self.runner_dir, env=env, text=True)
            self.wait_with_watchdogs()
            if self.current_runner_id and self.pat:
                delete_runner(self.repo_url, self.pat, self.current_runner_id)
            if self.current_runner_id:
                remove_record(self.current_runner_id)
            self.current_runner_id = ""
            self.log("runner exited, flushing state")
            time.sleep(self.restart_delay)

    def register_persistent(self) -> bool:
        try:
            token = self.registration_token()
        except RuntimeError:
            self.log("could not obtain registration token")
            return False
        self.log(f"config.sh --url {self.repo_url}")
        proc = subprocess.run(
            [
                "./config.sh",
                "--unattended",
                "--replace",
                "--url",
                self.repo_url,
                "--token",
                token,
                "--name",
                self.title,
                "--work",
                "_work",
                "--labels",
                self.runner_labels,
            ],
            cwd=self.runner_dir,
            check=False,
        )
        return proc.returncode == 0

    def run_persistent(self) -> int:
        self.materialise()
        while not self.register_persistent():
            self.log(f"registration failed; retrying in {self.restart_delay}s")
            time.sleep(self.restart_delay)
        self.sweep_persistent_storage()
        while True:
            env = os.environ.copy()
            env["RUNNER_PERSISTENT_STORAGE"] = self.persistent_storage_path
            self.log("running (persistent)")
            self.run_proc = subprocess.Popen(["./run.sh"], cwd=self.runner_dir, env=env, text=True)
            self.wait_with_watchdogs()
            self.log(f"run.sh exited; restarting in {self.restart_delay}s")
            time.sleep(self.restart_delay)


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: start-runner.py <title> <repo_url> <token> <workdir>", file=sys.stderr)
        return 2
    supervisor = RunnerSupervisor(*sys.argv[1:5])
    signal.signal(signal.SIGTERM, supervisor.stop_child)
    signal.signal(signal.SIGINT, supervisor.stop_child)
    return supervisor.run_ephemeral() if supervisor.ephemeral else supervisor.run_persistent()


if __name__ == "__main__":
    raise SystemExit(main())
