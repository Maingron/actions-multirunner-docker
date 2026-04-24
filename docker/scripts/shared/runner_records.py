"""Helpers for loading normalized runner records from parse-config.py."""

from __future__ import annotations

import subprocess
from dataclasses import dataclass


US = "\x1f"


@dataclass
class RunnerRecord:
    title: str
    repo_url: str
    token: str
    workdir: str
    ephemeral: bool
    pat: str
    labels: str
    group: str
    idle_regeneration: int
    image: str
    startup_script: str
    additional_packages: str
    watchdog_enabled: bool
    watchdog_interval: int
    docker_enabled: bool
    instances_min: int
    instances_max: int
    instances_headroom: int
    persistent_storage_enabled: bool
    persistent_storage_ttl: int
    persistent_storage_scope: str


def load_runner_records(config_file: str, parser_path: str) -> list[RunnerRecord]:
    proc = subprocess.run(
        ["python3", parser_path, config_file],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        raise ValueError(proc.stderr.strip() or f"failed to load runner records from {config_file}")

    records: list[RunnerRecord] = []
    for line in proc.stdout.splitlines():
        if not line:
            continue
        fields = line.split(US)
        if len(fields) != 21:
            raise ValueError(f"unexpected runner record width: {len(fields)}")
        records.append(
            RunnerRecord(
                title=fields[0],
                repo_url=fields[1],
                token=fields[2],
                workdir=fields[3],
                ephemeral=fields[4] == "1",
                pat=fields[5],
                labels=fields[6],
                group=fields[7],
                idle_regeneration=int(fields[8] or "0"),
                image=fields[9],
                startup_script=fields[10],
                additional_packages=fields[11],
                watchdog_enabled=fields[12] == "1",
                watchdog_interval=int(fields[13] or "0"),
                docker_enabled=fields[14] == "1",
                instances_min=int(fields[15] or "1"),
                instances_max=int(fields[16] or fields[15] or "1"),
                instances_headroom=int(fields[17] or "0"),
                persistent_storage_enabled=fields[18] == "1",
                persistent_storage_ttl=int(fields[19] or "0"),
                persistent_storage_scope=fields[20] or "shared",
            )
        )
    return records
