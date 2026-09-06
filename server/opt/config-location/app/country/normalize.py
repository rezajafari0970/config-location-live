from __future__ import annotations


def normalize_country_code(value: str | None) -> str | None:
    if value is None:
        return None

    code = str(value).strip().upper()

    if len(code) != 2:
        return None

    if not code.isalpha():
        return None

    return code


def normalize_country_name(value: str | None) -> str | None:
    if value is None:
        return None

    name = " ".join(str(value).strip().split())

    return name or None


def country_flag(code: str | None) -> str | None:
    code = normalize_country_code(code)

    if code is None:
        return None

    return "".join(
        chr(0x1F1E6 + ord(ch) - ord("A"))
        for ch in code
    )
