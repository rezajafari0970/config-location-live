from __future__ import annotations

import os
import shutil
import socket
import subprocess
import time
import uuid

from dataclasses import dataclass
from pathlib import Path


class SandboxError(RuntimeError):
    pass


class SandboxPortError(SandboxError):
    pass


class SandboxProcessError(SandboxError):
    pass


@dataclass(frozen=True)
class SandboxPaths:
    root: Path
    config: Path
    stdout: Path
    stderr: Path
    pid: Path


def allocate_loopback_port() -> int:
    with socket.socket(
        socket.AF_INET,
        socket.SOCK_STREAM,
    ) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def port_is_free(port: int) -> bool:
    with socket.socket(
        socket.AF_INET,
        socket.SOCK_STREAM,
    ) as sock:
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            return False
        return True


class XraySandbox:

    def __init__(
        self,
        *,
        base_dir: Path,
        xray_binary: Path,
        config_id: str,
    ) -> None:

        token = uuid.uuid4().hex

        safe_id = "".join(
            c if c.isalnum() or c in "._-"
            else "_"
            for c in config_id
        )[:80]

        root = (
            base_dir
            / f"{safe_id}-{token}"
        )

        self.paths = SandboxPaths(
            root=root,
            config=root / "config.json",
            stdout=root / "xray.stdout.log",
            stderr=root / "xray.stderr.log",
            pid=root / "xray.pid",
        )

        self.xray_binary = xray_binary
        self.socks_port: int | None = None
        self.process: subprocess.Popen | None = None

    def create(self) -> None:
        self.paths.root.mkdir(
            parents=True,
            exist_ok=False,
            mode=0o700,
        )

        os.chmod(
            self.paths.root,
            0o700,
        )

        self.socks_port = allocate_loopback_port()

        if not port_is_free(self.socks_port):
            raise SandboxPortError(
                "allocated port is not free"
            )

    def write_config(
        self,
        content: str,
    ) -> None:

        if not self.paths.root.exists():
            raise SandboxError(
                "sandbox not created"
            )

        self.paths.config.write_text(
            content,
            encoding="utf-8",
        )

        os.chmod(
            self.paths.config,
            0o600,
        )

    def start(
        self,
        *,
        extra_args: tuple[str, ...] = (),
    ) -> None:

        if self.process is not None:
            raise SandboxProcessError(
                "process already started"
            )

        if not self.paths.config.exists():
            raise SandboxProcessError(
                "runtime config missing"
            )

        stdout = self.paths.stdout.open("ab")
        stderr = self.paths.stderr.open("ab")

        try:
            self.process = subprocess.Popen(
                [
                    str(self.xray_binary),
                    "run",
                    "-c",
                    str(self.paths.config),
                    *extra_args,
                ],
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                cwd=str(self.paths.root),
                start_new_session=True,
                close_fds=True,
            )
        finally:
            stdout.close()
            stderr.close()

        self.paths.pid.write_text(
            str(self.process.pid),
            encoding="ascii",
        )

        os.chmod(
            self.paths.pid,
            0o600,
        )

    def wait_started(
        self,
        timeout: float = 5.0,
    ) -> bool:

        if self.process is None:
            raise SandboxProcessError(
                "process not started"
            )

        deadline = time.monotonic() + timeout

        while time.monotonic() < deadline:

            if self.process.poll() is not None:
                return False

            if self.socks_port is not None:
                with socket.socket(
                    socket.AF_INET,
                    socket.SOCK_STREAM,
                ) as sock:

                    sock.settimeout(0.1)

                    if (
                        sock.connect_ex(
                            (
                                "127.0.0.1",
                                self.socks_port,
                            )
                        )
                        == 0
                    ):
                        return True

            time.sleep(0.05)

        return False

    def terminate(
        self,
        timeout: float = 3.0,
    ) -> None:

        process = self.process

        if process is None:
            return

        if process.poll() is not None:
            return

        process.terminate()

        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=timeout)

    def cleanup(self) -> None:

        self.terminate()

        if self.paths.root.exists():
            shutil.rmtree(
                self.paths.root,
                ignore_errors=False,
            )

    def __enter__(self):
        self.create()
        return self

    def __exit__(
        self,
        exc_type,
        exc,
        tb,
    ):
        self.cleanup()
        return False
