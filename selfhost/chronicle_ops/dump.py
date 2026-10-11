"""Restricted pg_dump framing, completion and gzip integrity (Python 3.9)."""

import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import zlib

COMPLETE = b"-- PostgreSQL database dump complete"
EXIT_REJECTED_BEFORE_MUTATION = 46
EXIT_RESTORE_TRANSACTION_ROLLED_BACK = 47
BACKUP_MAX_AGE_SECONDS = 36 * 60 * 60
BACKUP_SCRATCH_FACTOR = 2


def backup_marker(backups, database):
    if not database or any(c in database for c in "/\\\r\n\0"):
        raise DumpError("unsafe backup database name")
    return Path(backups) / "last" / f"{database}-verified.json"


def publish_backup(path, database, source):
    path = Path(path)
    marker = backup_marker(path.parent.parent, database)
    temporary = marker.with_name(marker.name + ".partial")
    try:
        with temporary.open("w") as output:
            os.chmod(temporary, 0o600)
            json.dump(dict(source, database=database, file=path.name, sha256=file_sha256(path), verified_at=time.time()), output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, marker)
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        temporary.unlink(missing_ok=True)


def verified_backup(backups, database):
    marker = backup_marker(backups, database)
    data = json.loads(marker.read_text())
    if data.get("database") != database or not 0 <= time.time() - data["verified_at"] <= BACKUP_MAX_AGE_SECONDS:
        raise DumpError("verified backup belongs to another database or is stale")
    name = data["file"]
    if Path(name).name != name or not name.startswith(database + "-") or not name.endswith(".sql.gz"):
        raise DumpError("invalid verified backup path")
    path = marker.parent / name
    validate_dump(path, data["sha256"])
    return path, data


class DumpError(ValueError):
    pass


def file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_dump(lines):
    restricted = finished = copying = header = failed = complete = in_statement = False
    comment = 0  # PostgreSQL block comments nest.
    quote = token = ""
    for raw in lines:
        line = raw.decode("latin1").rstrip("\n")
        # pg_dump writes neither NUL nor CR (COPY escapes both). psql drops a line's text after
        # NUL and ends a -- comment at CR, so either would split what psql runs from what we lex.
        failed |= "\0" in line or "\r" in line
        if copying:
            if line == "\\.":
                copying = False
            continue
        match = None if quote or comment else re.fullmatch(r"\\restrict ([A-Za-z0-9]+)", line)
        if match:
            failed |= restricted or finished
            restricted, token = True, match[1]
            continue
        match = None if quote or comment else re.fullmatch(r"\\unrestrict ([A-Za-z0-9]+)", line)
        if match:
            failed |= not restricted or finished or match[1] != token
            finished = True
            continue
        if not quote and not comment and re.match(r"\s*\\", line, re.ASCII):
            failed = True
            continue
        if not quote and not comment:
            if line == "-- PostgreSQL database dump":
                failed |= header or restricted or finished
                header = True
                continue
            if line == COMPLETE.decode("ascii"):
                failed |= complete or not header or not restricted
                complete = True
                continue
            if re.fullmatch(r"\s*(--.*)?", line, re.ASCII):
                continue
        failed |= complete
        failed |= not restricted or finished
        code, i = "", 0
        while i < len(line):
            c, nextc = line[i], line[i + 1:i + 2]
            if comment:
                if c == "*" and nextc == "/":
                    comment -= 1
                    i += 1
                elif c == "/" and nextc == "*":
                    comment += 1
                    i += 1
            elif quote in ("single", "double"):
                mark = "'" if quote == "single" else '"'
                if c == mark:
                    if nextc == mark:
                        i += 1
                    else:
                        quote = ""
                # A backslash escapes the quote only in E'' strings or with standard_conforming_strings
                # off, which a dump could switch. pg_dump's DDL has none, so refuse rather than guess.
                elif quote == "single" and c == "\\":
                    failed = True
            elif quote:
                if line[i:i + len(quote)] == quote:
                    i += len(quote) - 1
                    quote = ""
            elif c == "-" and nextc == "-":
                break
            elif c == "/" and nextc == "*":
                comment = 1
                code += " "  # A comment separates tokens, as whitespace does.
                i += 1
            elif c in ("'", '"'):
                quote = "single" if c == "'" else "double"
            elif c == "$" and (tag := re.match(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$", line[i:])):
                # psql reads foo$tag$ as one identifier; pg_dump quotes identifiers containing $.
                failed |= i > 0 and bool(re.match(r"[A-Za-z0-9_$\x80-\xff]", line[i - 1]))
                quote = tag[0]
                i += len(quote) - 1
            else:
                code += c
            i += 1
        failed |= "\\" in code or bool(re.search(r"(^|[^A-Z0-9_])PROGRAM([^A-Z0-9_]|$)", code.upper()))
        # pg_dump quotes every identifier that is not plain ASCII, so unquoted high-bit bytes (which
        # psql reads as identifier or dollar-tag characters) are not its output.
        failed |= bool(re.search(r"[\x80-\xff]", code))
        # psql joins lines until an unquoted semicolon, so a keyword starts a transaction-control
        # statement only at a statement boundary; mid-statement START WITH or CASE ... END is data.
        boundary = ";" if not in_statement else ""
        failed |= bool(re.search(r";\s*(BEGIN|START|COMMIT|END|ROLLBACK|ABORT|PREPARE)\b",
                                 boundary + code, re.I))
        if code.strip():
            in_statement = not code.rstrip().endswith(";")
        if re.fullmatch(r"COPY .* FROM STDIN;", code.upper()):
            copying = True
    return not (failed or not header or not restricted or not finished or not complete or copying or quote or comment)


def validate_dump(path, expected=None):
    if expected is not None:
        if not re.fullmatch("[0-9a-f]{64}", expected):
            raise DumpError("requires an independently reviewed --trusted-sha256 digest")
        if file_sha256(path) != expected:
            raise DumpError("provenance digest mismatch")
    try:
        with gzip.open(path, "rb") as stream:
            safe = safe_dump(stream)  # Read to EOF so gzip checks the CRC and trailer too.
            size = stream.tell()
    except (OSError, EOFError, zlib.error):
        raise DumpError("failed gzip integrity verification (truncated or corrupt)") from None
    if not safe:
        raise DumpError("lacks safe pg_dump restricted framing or contains executable commands or lacks the final PostgreSQL database dump complete marker")

    return size


if __name__ == "__main__":
    try:
        validate_dump(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
    except (OSError, DumpError) as error:
        print("FAIL restore " + str(error), file=sys.stderr)
        sys.exit(EXIT_REJECTED_BEFORE_MUTATION)
