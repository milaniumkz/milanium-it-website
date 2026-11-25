#!/usr/bin/env python3
"""Validate the tiny MILANIUM deploy config without touching Docker, DNS or the server."""
import argparse
from pathlib import Path
import re
import sys

KEYS = {"MILANIUM_IMAGE", "MILANIUM_HOST_PORT", "MILANIUM_CONTAINER_PORT"}
IMAGE = re.compile(r"[a-z0-9][a-z0-9.-]*(?::[0-9]{1,5})?(?:/[a-z0-9]+(?:[._-]+[a-z0-9]+)*)+@sha256:[a-f0-9]{64}\Z")


def validate(path: Path) -> None:
    config = {}
    for line_no, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or key not in KEYS or key in config:
            raise ValueError(f"Строка {line_no}: неизвестный, некорректный или повторный параметр.")
        config[key] = value
    if set(config) != KEYS:
        raise ValueError("Нужны ровно три параметра из deploy/.env.example.")
    if not IMAGE.fullmatch(config["MILANIUM_IMAGE"]):
        raise ValueError("MILANIUM_IMAGE: нужен полный адрес образа с @sha256:<64 символа>.")
    for key in ("MILANIUM_HOST_PORT", "MILANIUM_CONTAINER_PORT"):
        value = config[key]
        if not re.fullmatch(r"[1-9][0-9]{0,4}", value) or not 1024 <= int(value) <= 65535:
            raise ValueError(f"{key}: укажите числовой порт 1024–65535.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    args = parser.parse_args()
    try:
        validate(args.config)
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"Конфигурация не готова: {exc}", file=sys.stderr)
        raise SystemExit(1) from None
    print("Формат прошёл проверку. Хост, образ и порты ещё не проверены.")
