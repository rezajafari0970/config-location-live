from __future__ import annotations

import json
import math
import os
import socket
import statistics
import subprocess
import time

from dataclasses import dataclass
from pathlib import Path
from typing import Any


POLICY_PATH = Path(
    "/etc/config-location/health-adaptive.json"
)


@dataclass(frozen=True)
class ResourceSnapshot:
    cpu_percent: float

    memory_available_mb: float
    memory_total_mb: float

    fd_allocated: int
    fd_limit: int
    fd_percent: float

    health_xray_processes: int

    interface: str | None
    interface_speed_mbps: float | None

    rx_mbps: float
    tx_mbps: float


@dataclass(frozen=True)
class NetworkSnapshot:
    success_ratio: float
    median_latency_ms: float | None

    successful: int
    total: int

    degraded: bool
    critical: bool


@dataclass(frozen=True)
class ProjectSnapshot:
    services_ok: bool
    failed_services: tuple[str, ...]

    baseline_ports: tuple[int, ...]
    failed_ports: tuple[int, ...]

    healthy: bool


@dataclass(frozen=True)
class AdaptiveDecision:
    workers: int
    batch_size: int

    pause: bool
    reason: str

    cpu_factor: float
    memory_factor: float
    fd_factor: float
    network_factor: float
    history_factor: float

    worker_ceiling: int
    network_budget_mbps: float


def load_policy(
    path: Path = POLICY_PATH,
) -> dict[str, Any]:

    value = json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    return value


def _read_cpu_times() -> tuple[int, int]:

    parts = (
        Path("/proc/stat")
        .read_text(
            encoding="utf-8"
        )
        .splitlines()[0]
        .split()
    )

    values = [
        int(x)
        for x in parts[1:]
    ]

    idle = (
        values[3]
        + (
            values[4]
            if len(values) > 4
            else 0
        )
    )

    total = sum(values)

    return total, idle


def cpu_percent(
    sample_seconds: float = 0.20,
) -> float:

    total1, idle1 = (
        _read_cpu_times()
    )

    time.sleep(
        sample_seconds
    )

    total2, idle2 = (
        _read_cpu_times()
    )

    delta_total = max(
        1,
        total2 - total1,
    )

    delta_idle = (
        idle2 - idle1
    )

    busy = (
        1.0
        - (
            delta_idle
            / delta_total
        )
    )

    return max(
        0.0,
        min(
            100.0,
            busy * 100.0,
        ),
    )


def memory_info() -> tuple[
    float,
    float,
]:

    values = {}

    for line in (
        Path("/proc/meminfo")
        .read_text(
            encoding="utf-8"
        )
        .splitlines()
    ):

        if ":" not in line:
            continue

        key, value = (
            line.split(
                ":",
                1,
            )
        )

        number = (
            value.strip()
            .split()[0]
        )

        try:
            values[key] = int(
                number
            )
        except Exception:
            pass


    total = (
        values.get(
            "MemTotal",
            0,
        )
        / 1024
    )

    available = (
        values.get(
            "MemAvailable",
            0,
        )
        / 1024
    )

    return (
        available,
        total,
    )


def fd_info() -> tuple[
    int,
    int,
    float,
]:

    parts = (
        Path(
            "/proc/sys/fs/file-nr"
        )
        .read_text(
            encoding="utf-8"
        )
        .split()
    )

    allocated = int(
        parts[0]
    )

    limit = int(
        Path(
            "/proc/sys/fs/file-max"
        )
        .read_text(
            encoding="utf-8"
        )
        .strip()
    )

    percent = (
        allocated
        / max(
            1,
            limit,
        )
        * 100.0
    )

    return (
        allocated,
        limit,
        percent,
    )


def health_xray_count() -> int:

    count = 0

    proc = Path(
        "/proc"
    )

    for path in proc.iterdir():

        if not path.name.isdigit():
            continue

        try:

            cmdline = (
                path
                .joinpath(
                    "cmdline"
                )
                .read_bytes()
                .replace(
                    b"\x00",
                    b" ",
                )
                .decode(
                    "utf-8",
                    errors="ignore",
                )
            )

        except Exception:
            continue

        if (
            "xray" in cmdline.lower()
            and
            "/var/lib/config-location/"
            "health-sandboxes"
            in cmdline
        ):
            count += 1

    return count


def default_interface() -> str | None:

    try:

        for line in (
            Path(
                "/proc/net/route"
            )
            .read_text(
                encoding="utf-8"
            )
            .splitlines()[1:]
        ):

            parts = (
                line.split()
            )

            if (
                len(parts) >= 3
                and parts[1]
                == "00000000"
            ):
                return parts[0]

    except Exception:
        pass

    return None


def interface_speed(
    interface: str | None,
) -> float | None:

    if not interface:
        return None

    path = (
        Path(
            "/sys/class/net"
        )
        / interface
        / "speed"
    )

    try:

        value = float(
            path.read_text(
                encoding="utf-8"
            ).strip()
        )

        if value <= 0:
            return None

        return value

    except Exception:
        return None


def interface_bytes(
    interface: str | None,
) -> tuple[int, int]:

    if not interface:
        return 0, 0

    for line in (
        Path(
            "/proc/net/dev"
        )
        .read_text(
            encoding="utf-8"
        )
        .splitlines()
    ):

        if ":" not in line:
            continue

        name, values = (
            line.split(
                ":",
                1,
            )
        )

        if (
            name.strip()
            != interface
        ):
            continue

        fields = (
            values.split()
        )

        if len(fields) < 9:
            return 0, 0

        return (
            int(fields[0]),
            int(fields[8]),
        )

    return 0, 0


def network_usage(
    interface: str | None,
    sample_seconds: float = 0.40,
) -> tuple[
    float,
    float,
]:

    rx1, tx1 = (
        interface_bytes(
            interface
        )
    )

    started = (
        time.monotonic()
    )

    time.sleep(
        sample_seconds
    )

    rx2, tx2 = (
        interface_bytes(
            interface
        )
    )

    elapsed = max(
        0.001,
        time.monotonic()
        - started,
    )

    rx_mbps = (
        max(
            0,
            rx2 - rx1,
        )
        * 8
        / elapsed
        / 1_000_000
    )

    tx_mbps = (
        max(
            0,
            tx2 - tx1,
        )
        * 8
        / elapsed
        / 1_000_000
    )

    return (
        rx_mbps,
        tx_mbps,
    )


def collect_resources() -> ResourceSnapshot:

    interface = (
        default_interface()
    )

    available, total = (
        memory_info()
    )

    fd_allocated, fd_limit, fd_percent = (
        fd_info()
    )

    rx_mbps, tx_mbps = (
        network_usage(
            interface
        )
    )

    return ResourceSnapshot(
        cpu_percent=(
            cpu_percent()
        ),

        memory_available_mb=
            available,

        memory_total_mb=
            total,

        fd_allocated=
            fd_allocated,

        fd_limit=
            fd_limit,

        fd_percent=
            fd_percent,

        health_xray_processes=
            health_xray_count(),

        interface=
            interface,

        interface_speed_mbps=
            interface_speed(
                interface
            ),

        rx_mbps=
            rx_mbps,

        tx_mbps=
            tx_mbps,
    )


DIRECT_TARGETS = (
    (
        "cloudflare",
        "https://speed.cloudflare.com/"
    ),
    (
        "google",
        "https://www.google.com/generate_204"
    ),
    (
        "microsoft",
        "https://www.microsoft.com/"
    ),
)


def collect_network(
    *,
    timeout_seconds: float,
    baseline_latency_ms: float | None = None,
    degraded_multiplier: float = 2.5,
    minimum_success_ratio: float = 0.67,
    critical_success_ratio: float = 0.34,
) -> NetworkSnapshot:

    latencies = []
    successful = 0


    for _name, url in DIRECT_TARGETS:

        command = [
            "curl",
            "--silent",
            "--show-error",
            "--location",
            "--output",
            "/dev/null",

            "--connect-timeout",
            str(
                min(
                    2.0,
                    timeout_seconds,
                )
            ),

            "--max-time",
            str(
                timeout_seconds
            ),

            "--write-out",
            "%{http_code} "
            "%{time_connect} "
            "%{time_starttransfer}",

            url,
        ]


        try:

            result = subprocess.run(
                command,

                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,

                text=True,

                timeout=(
                    timeout_seconds
                    + 1
                ),
            )

        except Exception:
            continue


        if result.returncode != 0:
            continue


        parts = (
            result.stdout
            .strip()
            .split()
        )

        if len(parts) < 3:
            continue


        try:

            code = int(
                float(
                    parts[0]
                )
            )

            connect = float(
                parts[1]
            )

            starttransfer = float(
                parts[2]
            )

        except Exception:
            continue


        if code <= 0:
            continue


        successful += 1

        latency = max(
            connect,
            starttransfer,
        ) * 1000.0

        latencies.append(
            latency
        )


    total = len(
        DIRECT_TARGETS
    )

    ratio = (
        successful
        / total
    )


    median = (
        statistics.median(
            latencies
        )
        if latencies
        else None
    )


    critical = (
        ratio
        < critical_success_ratio
    )


    degraded = (
        ratio
        < minimum_success_ratio
    )


    if (
        not degraded
        and baseline_latency_ms
        and median is not None
        and baseline_latency_ms > 0
        and median
        > (
            baseline_latency_ms
            * degraded_multiplier
        )
    ):
        degraded = True


    return NetworkSnapshot(
        success_ratio=ratio,

        median_latency_ms=
            median,

        successful=
            successful,

        total=
            total,

        degraded=
            degraded,

        critical=
            critical,
    )


def service_active(
    name: str,
) -> bool:

    result = subprocess.run(
        [
            "systemctl",
            "is-active",
            "--quiet",
            name,
        ],

        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    return (
        result.returncode
        == 0
    )


def port_open(
    port: int,
) -> bool:

    try:

        with socket.create_connection(
            (
                "127.0.0.1",
                int(port),
            ),
            timeout=0.5,
        ):
            return True

    except Exception:
        return False


def discover_baseline_ports(
    candidates: list[int],
) -> tuple[int, ...]:

    return tuple(
        int(port)
        for port in candidates
        if port_open(
            int(port)
        )
    )


def collect_projects(
    *,
    services: list[str],
    baseline_ports: tuple[int, ...],
) -> ProjectSnapshot:

    failed_services = tuple(
        name
        for name in services
        if not service_active(
            name
        )
    )


    failed_ports = tuple(
        port
        for port in baseline_ports
        if not port_open(
            port
        )
    )


    healthy = (
        not failed_services
        and not failed_ports
    )


    return ProjectSnapshot(
        services_ok=(
            not failed_services
        ),

        failed_services=
            failed_services,

        baseline_ports=
            baseline_ports,

        failed_ports=
            failed_ports,

        healthy=
            healthy,
    )


def clamp(
    value: float,
    low: float,
    high: float,
) -> float:

    return max(
        low,
        min(
            high,
            value,
        ),
    )


def decide(
    *,
    policy: dict[str, Any],

    resources: ResourceSnapshot,
    network: NetworkSnapshot,
    projects: ProjectSnapshot,

    discovered: int,

    previous_metrics: dict[str, Any] | None,
) -> AdaptiveDecision:

    workers_cfg = (
        policy["workers"]
    )

    batch_cfg = (
        policy["batch"]
    )

    server_cfg = (
        policy["server_guard"]
    )

    network_cfg = (
        policy["network_guard"]
    )


    min_workers = int(
        workers_cfg["min"]
    )

    soft_max = int(
        workers_cfg["soft_max"]
    )

    hard_max = int(
        workers_cfg["hard_max"]
    )


    if not projects.healthy:

        return AdaptiveDecision(
            workers=0,
            batch_size=0,

            pause=True,
            reason="protected_project_unhealthy",

            cpu_factor=0,
            memory_factor=0,
            fd_factor=0,
            network_factor=0,
            history_factor=0,

            worker_ceiling=0,
            network_budget_mbps=0,
        )


    if network.critical:

        return AdaptiveDecision(
            workers=0,
            batch_size=0,

            pause=True,
            reason="global_network_critical",

            cpu_factor=0,
            memory_factor=0,
            fd_factor=0,
            network_factor=0,
            history_factor=0,

            worker_ceiling=0,
            network_budget_mbps=0,
        )


    cpu = (
        resources.cpu_percent
    )


    if (
        cpu
        >= float(
            server_cfg[
                "critical_cpu_percent"
            ]
        )
    ):

        return AdaptiveDecision(
            workers=0,
            batch_size=0,

            pause=True,
            reason="server_cpu_critical",

            cpu_factor=0,
            memory_factor=0,
            fd_factor=0,
            network_factor=0,
            history_factor=0,

            worker_ceiling=0,
            network_budget_mbps=0,
        )


    target_cpu = float(
        server_cfg[
            "target_cpu_percent"
        ]
    )

    max_cpu = float(
        server_cfg[
            "max_cpu_percent"
        ]
    )


    if cpu <= target_cpu:
        cpu_factor = 1.0

    else:

        cpu_factor = clamp(
            1.0
            - (
                (
                    cpu
                    - target_cpu
                )
                /
                max(
                    1.0,
                    (
                        max_cpu
                        - target_cpu
                    ),
                )
                * 0.80
            ),
            0.20,
            1.0,
        )


    reserve_ram = float(
        server_cfg[
            "reserve_ram_mb"
        ]
    )

    ram_per_worker = float(
        server_cfg[
            "estimated_ram_per_worker_mb"
        ]
    )


    usable_ram = max(
        0.0,
        resources.memory_available_mb
        - reserve_ram,
    )


    ram_worker_ceiling = int(
        usable_ram
        / max(
            1.0,
            ram_per_worker,
        )
    )


    memory_factor = clamp(
        (
            ram_worker_ceiling
            / max(
                1,
                soft_max,
            )
        ),
        0.05,
        1.0,
    )


    fd_limit_percent = float(
        server_cfg[
            "max_fd_percent"
        ]
    )


    if (
        resources.fd_percent
        >= fd_limit_percent
    ):
        fd_factor = 0.20

    else:

        fd_factor = clamp(
            (
                fd_limit_percent
                - resources.fd_percent
            )
            / max(
                1.0,
                fd_limit_percent,
            )
            + 0.20,
            0.20,
            1.0,
        )


    if network.degraded:
        network_factor = 0.25

    elif (
        network.success_ratio
        < 1.0
    ):
        network_factor = 0.60

    else:
        network_factor = 1.0


    link_speed = (
        resources.interface_speed_mbps
    )


    if (
        link_speed
        and link_speed > 0
    ):

        network_budget = (
            link_speed
            * float(
                network_cfg[
                    "max_health_link_fraction"
                ]
            )
        )

    else:

        network_budget = float(
            network_cfg[
                "fallback_health_budget_mbps"
            ]
        )


    current_network = max(
        resources.rx_mbps,
        resources.tx_mbps,
    )


    remaining_budget = max(
        1.0,
        network_budget
        - current_network,
    )


    previous = (
        previous_metrics
        or {}
    )


    observed_worker_mbps = float(
        previous.get(
            "estimated_worker_mbps",
            1.5,
        )
    )


    observed_worker_mbps = clamp(
        observed_worker_mbps,
        0.25,
        10.0,
    )


    network_worker_ceiling = int(
        remaining_budget
        / observed_worker_mbps
    )


    history_factor = 1.0


    previous_error_ratio = float(
        previous.get(
            "error_ratio",
            0.0,
        )
    )


    previous_infra_ratio = float(
        previous.get(
            "infra_ratio",
            0.0,
        )
    )


    if (
        previous_error_ratio
        >= 0.03
        or previous_infra_ratio
        >= 0.05
    ):

        history_factor = 0.50


    elif (
        previous_error_ratio
        == 0
        and previous_infra_ratio
        == 0
        and cpu
        < target_cpu
        and not network.degraded
    ):

        history_factor = 1.10


    process_ceiling = max(
        0,
        int(
            server_cfg[
                "max_health_xray"
            ]
        )
        - resources.health_xray_processes,
    )


    worker_ceiling = min(
        hard_max,
        max(
            1,
            ram_worker_ceiling,
        ),
        max(
            1,
            network_worker_ceiling,
        ),
        max(
            1,
            process_ceiling,
        ),
    )


    base = min(
        soft_max,
        worker_ceiling,
    )


    combined_factor = min(
        cpu_factor,
        memory_factor,
        fd_factor,
        network_factor,
    )


    calculated = int(
        base
        * combined_factor
        * history_factor
    )


    workers = max(
        min_workers,
        calculated,
    )


    workers = min(
        workers,
        worker_ceiling,
        hard_max,
    )


    if workers <= 0:

        return AdaptiveDecision(
            workers=0,
            batch_size=0,

            pause=True,
            reason="resource_ceiling_zero",

            cpu_factor=
                cpu_factor,

            memory_factor=
                memory_factor,

            fd_factor=
                fd_factor,

            network_factor=
                network_factor,

            history_factor=
                history_factor,

            worker_ceiling=
                worker_ceiling,

            network_budget_mbps=
                network_budget,
        )


    target_seconds = float(
        batch_cfg[
            "target_cycle_seconds"
        ]
    )


    throughput = previous.get(
        "jobs_per_second"
    )


    if throughput is not None:

        try:
            throughput = float(
                throughput
            )

        except Exception:
            throughput = None


    if (
        throughput is None
        or throughput <= 0
    ):

        batch_estimate = (
            workers
            * 8
        )

    else:

        # Scale historical throughput to the
        # worker count selected for this cycle.
        previous_workers = max(
            1,
            int(
                previous.get(
                    "workers",
                    workers,
                )
            ),
        )

        scaled_throughput = (
            throughput
            * (
                workers
                / previous_workers
            )
        )

        batch_estimate = int(
            scaled_throughput
            * target_seconds
        )


    batch_size = max(
        int(
            batch_cfg["min"]
        ),
        batch_estimate,
    )


    batch_size = min(
        batch_size,
        int(
            batch_cfg["max"]
        ),
        discovered,
    )


    return AdaptiveDecision(
        workers=workers,
        batch_size=batch_size,

        pause=False,
        reason="adaptive_ready",

        cpu_factor=
            cpu_factor,

        memory_factor=
            memory_factor,

        fd_factor=
            fd_factor,

        network_factor=
            network_factor,

        history_factor=
            history_factor,

        worker_ceiling=
            worker_ceiling,

        network_budget_mbps=
            network_budget,
    )
