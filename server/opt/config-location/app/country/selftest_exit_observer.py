from __future__ import annotations

from .exit_observer import (
    ExitProbe,
    normalize_ip,
    observe_exit_ip,
)


def main() -> int:

    assert (
        normalize_ip(
            "8.8.8.8\n"
        )
        == "8.8.8.8"
    )

    assert (
        normalize_ip(
            "not-an-ip"
        )
        is None
    )

    assert (
        normalize_ip(
            "127.0.0.1"
        )
        is None
    )

    print(
        "[PASS] IP validation"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
