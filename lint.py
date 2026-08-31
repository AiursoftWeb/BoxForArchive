#!/usr/bin/env python3
from pathlib import Path
import re
import sys

import yaml


ROOT = Path(__file__).resolve().parent
EXPECTED_STACKS = {"download", "gitea", "peertube", "shepherd"}
FORBIDDEN_WORDS = {
    "localhost:8080",
    "pysyncer",
    "clickhouse",
    "grafana",
    "promtail",
    "loki",
    "puller",
    "zot",
}


def fail(message: str, errors: list[str]) -> None:
    errors.append(message)


def validate_compose(path: Path, errors: list[str]) -> None:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except Exception as error:
        fail(f"{path.relative_to(ROOT)}: invalid YAML: {error}", errors)
        return

    services = data.get("services")
    if not isinstance(services, dict) or not services:
        fail(f"{path.relative_to(ROOT)}: no services found", errors)
        return

    for name, service in services.items():
        image = str((service or {}).get("image", ""))
        if not image:
            fail(f"{path.relative_to(ROOT)}:{name}: image is required", errors)
        elif image != "boxforarchive/archive-caddy:latest" and not image.startswith(
            "pubhub.aiursoft.com/"
        ):
            fail(
                f"{path.relative_to(ROOT)}:{name}: remote image must come from PubHub",
                errors,
            )

        update = (service or {}).get("deploy", {}).get("update_config", {})
        if update.get("order") not in {"start-first", "stop-first"}:
            fail(f"{path.relative_to(ROOT)}:{name}: update order is required", errors)
        if "delay" not in update:
            fail(f"{path.relative_to(ROOT)}:{name}: update delay is required", errors)


def main() -> int:
    errors: list[str] = []
    compose_files = sorted(ROOT.glob("stage*/**/docker-compose.yml"))
    if not compose_files:
        fail("No docker-compose.yml files found", errors)

    for path in compose_files:
        validate_compose(path, errors)

    stack_root = ROOT / "stage4" / "stacks"
    actual_stacks = {path.name for path in stack_root.iterdir() if path.is_dir()}
    if actual_stacks != EXPECTED_STACKS:
        fail(
            f"stage4 stack set must be exactly {sorted(EXPECTED_STACKS)}, got {sorted(actual_stacks)}",
            errors,
        )

    scanned_files = [
        *compose_files,
        *sorted(ROOT.glob("stage*/**/Dockerfile")),
    ]
    for path in scanned_files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        lower = text.lower()
        for forbidden in FORBIDDEN_WORDS:
            if forbidden in lower:
                fail(f"{path.relative_to(ROOT)}: forbidden archive component '{forbidden}'", errors)

    caddy_sources = [
        ROOT / "stage2" / "images" / "sites" / "baseline",
        *sorted((ROOT / "stage4" / "stacks").glob("*/*.conf")),
    ]
    request_log_pattern = re.compile(r"^\s*log(?:\s|$)", re.MULTILINE)
    for path in caddy_sources:
        if request_log_pattern.search(path.read_text(encoding="utf-8")):
            fail(f"{path.relative_to(ROOT)}: HTTP access logging must remain disabled", errors)

    if errors:
        print("BoxForArchive validation failed:")
        for error in errors:
            print(f"  - {error}")
        return 1

    print(f"Validated {len(compose_files)} compose files; archive boundaries are intact.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
