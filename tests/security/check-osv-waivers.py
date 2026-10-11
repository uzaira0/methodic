#!/usr/bin/env python3
"""Fail unless every OSV waiver names a reason and expires within MAX_DAYS."""
import datetime
import sys
import tomllib

MAX_DAYS = 62


def problems(config: dict, now: datetime.datetime) -> list[str]:
    found = []
    for entry in config.get("IgnoredVulns", []):
        vuln = entry.get("id") or "<missing id>"
        until = entry.get("ignoreUntil")
        if not str(entry.get("reason", "")).strip():
            found.append(f"{vuln}: missing reason")
        if not isinstance(until, datetime.datetime):
            found.append(f"{vuln}: missing ignoreUntil")
        elif not now < until <= now + datetime.timedelta(days=MAX_DAYS):
            found.append(f"{vuln}: ignoreUntil {until.isoformat()} must be in the next {MAX_DAYS} days")
    return found


def self_test() -> None:
    now = datetime.datetime(2026, 10, 8, tzinfo=datetime.timezone.utc)
    soon = now + datetime.timedelta(days=30)
    assert not problems({"IgnoredVulns": [{"id": "A", "reason": "unused", "ignoreUntil": soon}]}, now)
    assert problems({"IgnoredVulns": [{"id": "A", "ignoreUntil": soon}]}, now)
    assert problems({"IgnoredVulns": [{"id": "A", "reason": "unused"}]}, now)
    assert problems({"IgnoredVulns": [{"id": "A", "reason": "unused", "ignoreUntil": now}]}, now)
    assert problems({"IgnoredVulns": [{"id": "A", "reason": "unused",
                                       "ignoreUntil": now + datetime.timedelta(days=MAX_DAYS + 1)}]}, now)


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit(0)
    now = datetime.datetime.now(datetime.timezone.utc)
    failures = []
    for path in sys.argv[1:]:
        with open(path, "rb") as handle:
            failures += [f"{path}: {problem}" for problem in problems(tomllib.load(handle), now)]
    print("\n".join(failures))
    sys.exit(1 if failures else 0)
