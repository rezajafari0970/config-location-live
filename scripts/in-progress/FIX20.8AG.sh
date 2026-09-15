#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

RT="$R/app/health/core/retry.py"
E="$R/app/health/core/engine.py"
D="$R/app/health/probes/download.py"
U="$R/app/health/probes/upload.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX20.8AG-$TS"

mkdir -p "$B"

cp -a "$RT" "$E" "$D" "$U" "$B/"

echo "BACKUP=$B"

export RT E D U

"$PY" <<'PY'
from pathlib import Path
import os

RT = Path(os.environ["RT"])
E  = Path(os.environ["E"])
D  = Path(os.environ["D"])
U  = Path(os.environ["U"])


def replace_once(path, old, new, name):
    text = path.read_text()

    if old not in text:
        raise RuntimeError(
            f"{name}: anchor not found"
        )

    path.write_text(
        text.replace(old, new, 1)
    )


# =========================================================
# retry.py
# =========================================================

text = RT.read_text()

sig_area = text[
    text.find("def run_health_with_retry"):
    text.find("def run_health_with_retry") + 700
]

if "cancel_check=None" not in sig_area:

    replace_once(
        RT,
        """    jitter_min: float = 0.05,
    jitter_max: float = 0.35,
) -> RetryExecution:
""",
        """    jitter_min: float = 0.05,
    jitter_max: float = 0.35,
    cancel_check=None,
) -> RetryExecution:
""",
        "retry-signature",
    )


text = RT.read_text()

if "health_cancelled" not in text:

    replace_once(
        RT,
        """    for attempt in range(
        retry_count + 1
    ):

        result = run_health_once(
""",
        """    for attempt in range(
        retry_count + 1
    ):

        if (
            cancel_check is not None
            and cancel_check()
        ):
            raise InterruptedError(
                "health_cancelled"
            )

        result = run_health_once(
""",
        "retry-cancel-check",
    )


text = RT.read_text()

p = text.find("result = run_health_once(")

if p < 0:
    raise RuntimeError(
        "run_health_once call missing"
    )

if "cancel_check=" not in text[p:p + 1200]:

    replace_once(
        RT,
        """            upload_payload_bytes=(
                upload_payload_bytes
            ),
        )
""",
        """            upload_payload_bytes=(
                upload_payload_bytes
            ),

            cancel_check=
                cancel_check,
        )
""",
        "retry-engine-propagation",
    )


text = RT.read_text()

if (
    "deadline = (" not in text
    and
    "time.sleep(" in text
):

    old = """        retries_used += 1

        time.sleep(
            random.uniform(
                jitter_min,
                jitter_max,
            )
        )
"""

    if old in text:

        new = """        retries_used += 1

        delay = random.uniform(
            jitter_min,
            jitter_max,
        )

        deadline = (
            time.monotonic()
            + delay
        )

        while (
            time.monotonic()
            < deadline
        ):
            if (
                cancel_check is not None
                and cancel_check()
            ):
                raise InterruptedError(
                    "health_cancelled"
                )

            time.sleep(
                min(
                    0.05,
                    max(
                        0.0,
                        deadline
                        - time.monotonic(),
                    ),
                )
            )
"""

        RT.write_text(
            text.replace(
                old,
                new,
                1,
            )
        )


# =========================================================
# engine.py
# =========================================================

text = E.read_text()

sig_area = text[
    text.find("def run_health_once"):
    text.find("def run_health_once") + 800
]

if "cancel_check=None" not in sig_area:

    replace_once(
        E,
        """    upload_timeout: float = 15.0,
    upload_payload_bytes: int = 65536,
) -> HealthResult:
""",
        """    upload_timeout: float = 15.0,
    upload_payload_bytes: int = 65536,
    cancel_check=None,
) -> HealthResult:
""",
        "engine-signature",
    )


text = E.read_text()

dp = text.find(
    "# Download fallback chain."
)

if dp < 0:
    raise RuntimeError(
        "download-chain missing"
    )

before = text[
    max(0, dp - 400):
    dp
]

if "health_cancelled" not in before:

    replace_once(
        E,
        """        # Download fallback chain.
""",
        """        if (
            cancel_check is not None
            and cancel_check()
        ):
            raise InterruptedError(
                "health_cancelled"
            )

        # Download fallback chain.
""",
        "engine-download-cancel",
    )


text = E.read_text()

p = text.find(
    "measurement = run_download("
)

if p < 0:
    raise RuntimeError(
        "run_download missing"
    )

if "cancel_check=" not in text[p:p + 600]:

    replace_once(
        E,
        """                timeout_seconds=download_timeout,
            )
""",
        """                timeout_seconds=download_timeout,
                cancel_check=cancel_check,
            )
""",
        "download-propagation",
    )


text = E.read_text()

up = text.find(
    "# Upload fallback chain."
)

if up < 0:
    raise RuntimeError(
        "upload-chain missing"
    )

before = text[
    max(0, up - 400):
    up
]

if "health_cancelled" not in before:

    replace_once(
        E,
        """        # Upload fallback chain.
""",
        """        if (
            cancel_check is not None
            and cancel_check()
        ):
            raise InterruptedError(
                "health_cancelled"
            )

        # Upload fallback chain.
""",
        "engine-upload-cancel",
    )


text = E.read_text()

p = text.find(
    "measurement = run_upload("
)

if p < 0:
    raise RuntimeError(
        "run_upload missing"
    )

if "cancel_check=" not in text[p:p + 800]:

    replace_once(
        E,
        """                payload_bytes=(
                    upload_payload_bytes
                ),
            )
""",
        """                payload_bytes=(
                    upload_payload_bytes
                ),
                cancel_check=cancel_check,
            )
""",
        "upload-propagation",
    )


# =========================================================
# shared cancellable subprocess implementation
# =========================================================

helper = '''
def _run_cancellable(
    command,
    *,
    timeout_seconds: float,
    cancel_check=None,
):
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    deadline = (
        time.monotonic()
        + timeout_seconds
    )

    try:

        while True:

            if (
                cancel_check is not None
                and cancel_check()
            ):

                process.terminate()

                try:
                    process.wait(
                        timeout=1.0
                    )

                except subprocess.TimeoutExpired:

                    process.kill()
                    process.wait(
                        timeout=1.0
                    )

                raise InterruptedError(
                    "probe_cancelled"
                )

            if (
                process.poll()
                is not None
            ):

                stdout, stderr = (
                    process.communicate()
                )

                return (
                    subprocess.CompletedProcess(
                        command,
                        process.returncode,
                        stdout,
                        stderr,
                    )
                )

            if (
                time.monotonic()
                >= deadline
            ):

                process.terminate()

                try:
                    process.wait(
                        timeout=1.0
                    )

                except subprocess.TimeoutExpired:

                    process.kill()
                    process.wait(
                        timeout=1.0
                    )

                raise subprocess.TimeoutExpired(
                    command,
                    timeout_seconds,
                )

            time.sleep(
                0.05
            )

    except BaseException:

        if (
            process.poll()
            is None
        ):

            process.kill()

            try:
                process.wait(
                    timeout=1.0
                )

            except Exception:
                pass

        raise


'''


for path in (D, U):

    text = path.read_text()

    if (
        "def _run_cancellable("
        not in text
    ):

        marker = (
            "\n\n@dataclass(frozen=True)\n"
        )

        if marker not in text:
            raise RuntimeError(
                f"helper anchor missing: {path}"
            )

        path.write_text(
            text.replace(
                marker,
                "\n\n"
                + helper
                + "@dataclass(frozen=True)\n",
                1,
            )
        )


# =========================================================
# download.py
# =========================================================

text = D.read_text()

p = text.find("def run_download(")

if p < 0:
    raise RuntimeError(
        "run_download definition missing"
    )

if "cancel_check=None" not in text[p:p + 600]:

    replace_once(
        D,
        """    proxy_url: str,
    timeout_seconds: float = 12.0,
) -> DownloadMeasurement:
""",
        """    proxy_url: str,
    timeout_seconds: float = 12.0,
    cancel_check=None,
) -> DownloadMeasurement:
""",
        "download-signature",
    )


text = D.read_text()

if "result = _run_cancellable(" not in text:

    replace_once(
        D,
        """        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_seconds + 3,
        )
""",
        """        result = _run_cancellable(
            command,
            timeout_seconds=(
                timeout_seconds + 3
            ),
            cancel_check=cancel_check,
        )
""",
        "download-popen",
    )


# =========================================================
# upload.py
# =========================================================

text = U.read_text()

p = text.find("def run_upload(")

if p < 0:
    raise RuntimeError(
        "run_upload definition missing"
    )

if "cancel_check=None" not in text[p:p + 700]:

    replace_once(
        U,
        """    timeout_seconds: float = 15.0,
    payload_bytes: int = 65536,
) -> UploadMeasurement:
""",
        """    timeout_seconds: float = 15.0,
    payload_bytes: int = 65536,
    cancel_check=None,
) -> UploadMeasurement:
""",
        "upload-signature",
    )


text = U.read_text()

if "result = _run_cancellable(" not in text:

    replace_once(
        U,
        """            result = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=timeout_seconds + 3,
            )
""",
        """            result = _run_cancellable(
                command,
                timeout_seconds=(
                    timeout_seconds + 3
                ),
                cancel_check=cancel_check,
            )
""",
        "upload-popen",
    )


print(
    "PATCH_APPLIED=YES"
)
PY


echo "=== PY COMPILE ==="

"$PY" -m py_compile \
"$RT" \
"$E" \
"$D" \
"$U"

echo "PY_COMPILE=PASS"


echo "=== IMPORT TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.health.core.retry import (
    run_health_with_retry,
)

from app.health.core.engine import (
    run_health_once,
)

from app.health.probes.download import (
    _run_cancellable,
    run_download,
)

from app.health.probes.upload import (
    run_upload,
)

print(
    "IMPORT_TEST=PASS"
)
PY


echo "=== DIRECT CANCEL TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
import time

from app.health.probes.download import (
    _run_cancellable,
)

started = time.monotonic()

try:

    _run_cancellable(
        [
            "sleep",
            "30",
        ],
        timeout_seconds=35,
        cancel_check=lambda: (
            time.monotonic()
            - started
            > 0.25
        ),
    )

except InterruptedError:

    elapsed = (
        time.monotonic()
        - started
    )

    print(
        "CANCEL_ELAPSED_SECONDS=",
        elapsed,
    )

    assert elapsed < 2.0

else:

    raise SystemExit(
        "cancel did not trigger"
    )

print(
    "DIRECT_CANCEL_TEST=PASS"
)
PY


echo "=== RESTART HEALTH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

STATE=$(
    systemctl is-active \
    config-location-health-adaptive.service
)

echo "HEALTH_STATE=$STATE"

test "$STATE" = active


echo "=== SERVICE DETAILS ==="

systemctl show \
config-location-health-adaptive.service \
-p ActiveState \
-p SubState \
-p Result \
-p MainPID \
--no-pager


echo "=== CONTRACT CHECK ==="

grep -n -A15 \
"def run_health_with_retry" \
"$RT"

grep -n -A15 \
"def run_health_once" \
"$E"

grep -n -A8 \
"def run_download" \
"$D"

grep -n -A9 \
"def run_upload" \
"$U"


echo "========================================"
echo "FIX20.8AG=PASS"
echo "RUNNING_JOB_CANCELLATION=INSTALLED"
echo "DOWNLOAD_CANCEL=INSTALLED"
echo "UPLOAD_CANCEL=INSTALLED"
echo "DIRECT_CANCEL_TEST=PASS"
echo "HEALTH_SERVICE=active"
echo "BACKUP=$B"
echo "========================================"
