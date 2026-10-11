#!/usr/bin/env python3
import argparse
import fnmatch
import os
import shutil
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET


def is_operator_script(path):
    """Python or shell source, including extensionless executables such as selfhost/chronicle."""
    if path.suffix in (".py", ".sh"):
        return True
    if path.suffix or not path.is_file():
        return False
    with path.open("rb") as handle:
        first = handle.readline(128)
    return first.startswith(b"#!") and any(name in first for name in (b"bash", b"sh", b"python"))

def git(repo, *arguments, required=True):
    result = subprocess.run(["git", "-C", str(repo), *arguments], capture_output=True, text=True)
    if required and result.returncode:
        raise ValueError(result.stderr.strip() or "git " + " ".join(arguments) + " failed")
    return result.stdout.strip() if result.returncode == 0 else None


def default_base(repo, ref=None):
    if ref:
        return git(repo, "rev-parse", "--verify", ref + "^{commit}")
    base = git(repo, "merge-base", "HEAD", "origin/main", required=False)
    if base is None:
        base = git(repo, "rev-parse", "--verify", "HEAD~1^{commit}", required=False)
    if base is None:
        raise ValueError(f"{repo}: cannot resolve a base; supply --base <ref>")
    return base


def waivers(repo):
    result = []
    path = repo / ".diff-coverage-waivers"
    if path.is_file():
        for number, line in enumerate(path.read_text().splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split(None, 1)
            if len(fields) != 2 or not fields[1].lstrip("# \t").strip():
                raise ValueError(f"{path}:{number}: waiver requires a path glob and a reason")
            result.append(fields[0])
    return result


def children(repo, base, only=None):
    modules = repo / ".gitmodules"
    if not modules.is_file():
        return []
    paths = git(repo, "config", "--file", str(modules), "--get-regexp", r"^submodule\..*\.path$", required=False)
    result = []
    for entry in (paths or "").splitlines():
        relative = entry.split(None, 1)[1]
        child = repo / relative
        if only is not None and child != only:
            continue
        if not (child / ".git").exists():
            recorded = git(repo, "ls-tree", base, "--", relative)
            current = git(repo, "ls-tree", "HEAD", "--", relative)
            if recorded != current:
                raise ValueError(f"{child}: changed submodule is uninitialized; run git submodule update --init {relative}")
            continue
        recorded = git(repo, "ls-tree", base, "--", relative)
        child_base = recorded.split()[2] if recorded and recorded.startswith("160000 ") else None
        if child_base and git(child, "cat-file", "-e", child_base + "^{commit}", required=False) is None:
            raise ValueError(f"{child}: recorded base {child_base} is unavailable locally")
        result.append((child, child_base or default_base(child)))
    return result


def changed_files(repo, base):
    tracked = git(repo, "diff", "--name-only", "--diff-filter=ACMR", "-z", base, "--")
    untracked = git(repo, "ls-files", "--others", "--exclude-standard", "-z")
    return set((tracked + "\0" + untracked).split("\0")) - {""}


def reports_and_roots(repo):
    xml, lcov, sources = [], [], ["."]
    for directory, dirs, files in os.walk(repo):
        here = Path(directory)
        dirs[:] = [d for d in dirs if d not in {".git", ".gradle", "node_modules", ".local", ".venv"}]
        relative = here.relative_to(repo).as_posix()
        if relative.endswith(("src/main/kotlin", "src/main/java")):
            sources.append(relative)
        if "/build/reports/jacoco/" in "/" + relative + "/":
            xml.extend(str(here / f) for f in files if f.endswith(".xml"))
        xml.extend(str(here / f) for f in files if f == "coverage.xml"
                   or relative in {"coverage", "build/coverage"} and f.endswith(".xml"))
        if relative in {"coverage", "chronicle-web/coverage"} and "lcov.info" in files:
            lcov.append(str(here / "lcov.info"))
    bash = repo / "build/coverage/bash-cobertura.xml"
    if bash.is_file():
        xml.append(str(bash))
    else:
        print(f"[diff-coverage] {repo}: Bash input build/coverage/bash-cobertura.xml absent; skipping that optional input", flush=True)
    return sorted(set(xml)), sorted(set(lcov)), sources


def check(repo, base, inherited=()):
    relative = repo.relative_to(root).as_posix()
    prefix = "" if relative == "." else relative + "/"
    scoped = list(inherited) + [(prefix, glob) for glob in waivers(repo)]
    subs = children(repo, base)
    subpaths = {p for p, _ in subs}
    files = changed_files(repo, base)
    exclusions = [p for p in files if any((prefix + p).startswith(scope)
                  and fnmatch.fnmatchcase((prefix + p)[len(scope):], glob) for scope, glob in scoped)]
    changes = [p for p in files if repo / p not in subpaths and p not in exclusions]
    failed = False
    if changes:
        xml, lcov, sources = reports_and_roots(repo)
        missing = []
        if not xml and not lcov:
            missing.append("no coverage reports found")
        if any(p.endswith((".kt", ".java")) and "/src/main/" in "/" + p for p in changes) and not xml:
            missing.append("changed JVM sources require JaCoCo XML")
        if any(p.endswith((".ts", ".tsx", ".js", ".jsx")) for p in changes) and not lcov:
            missing.append("changed web sources require coverage/lcov.info")
        measured = set()
        for report in xml:
            document = ET.parse(report).getroot()
            for package in document.findall(".//package"):
                for source in package.findall("sourcefile"):
                    for directory in sources:
                        measured.add((repo / directory / package.get("name", "") / source.get("name", "")).resolve())
            for source in document.findall(".//class"):
                filename = source.get("filename")
                if filename:
                    roots = ["."] + [node.text for node in document.findall("./sources/source") if node.text]
                    measured.update((repo / directory / filename).resolve() for directory in roots)
        for report in lcov:
            for line in Path(report).read_text().splitlines():
                if line.startswith("SF:"):
                    measured.add((repo / line[3:]).resolve())
        for path in changes:
            production_jvm = path.endswith((".kt", ".java")) and "/src/main/" in "/" + path
            production_web = path.endswith((".ts", ".tsx", ".js", ".jsx")) and not any(
                marker in path for marker in (".test.", ".spec.", "/tests/", "/__tests__/"))
            production_operator = is_operator_script(repo / path) and "tests" not in Path(path).parts
            if (production_jvm and xml or production_web and lcov or production_operator) and (repo / path).resolve() not in measured:
                missing.append(f"changed source {path} is absent from coverage reports")
        if missing:
            print(f"[diff-coverage] {repo}: {'; '.join(missing)}. Produce reports with "
                  "bash scripts/local-ci.sh jvm-smoke (JaCoCo), or "
                  "(cd chronicle-web && bun test --coverage --coverage-reporter=lcov) (lcov); "
                  "Python coverage XML must include the changed Python sources, and the Bash xtrace producer "
                  "must supply build/coverage/bash-cobertura.xml for changed Bash sources.", file=sys.stderr)
            failed = True
        # diff-cover cannot mix lcov and XML in one invocation.
        for reports in (xml, lcov):
            if not reports:
                continue
            command = ["diff-cover", *reports, "--compare-branch", base, "--diff-range-notation", "..",
                       "--fail-under", "80", "--include-untracked", "--src-roots", *sources]
            if exclusions:
                # diff-cover matches --exclude against the basename or the absolute path only.
                command += ["--exclude", *(str(repo / p) for p in exclusions)]
            print(f"[diff-coverage] {repo}: base={base}, {len(reports)} report(s)", flush=True)
            failed = subprocess.run(command, cwd=repo).returncode != 0 or failed
    else:
        print(f"[diff-coverage] {repo}: no unwaived changes", flush=True)
    for child, child_base in subs:
        failed = check(child, child_base, scoped) or failed
    return failed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Require 80% coverage of changed executable lines in each Git repository.")
    parser.add_argument("--base", help="root repository base (default: merge-base with origin/main, then HEAD~1)")
    parser.add_argument("--print-base", metavar="SUBMODULE",
                        help="print the base commit this gate uses for SUBMODULE, then exit")
    args = parser.parse_args()
    for command in ("git",) if args.print_base else ("git", "diff-cover"):
        if shutil.which(command) is None:
            print(f"[diff-coverage] missing required command: {command}", file=sys.stderr)
            sys.exit(127)
    try:
        root = Path(git(Path.cwd(), "rev-parse", "--show-toplevel"))
        base = default_base(root, args.base)
        if args.print_base:
            submodule = root / args.print_base
            print(dict(children(root, base, only=submodule)).get(submodule) or default_base(submodule))
            sys.exit(0)
        sys.exit(1 if check(root, base) else 0)
    except (ValueError, OSError, ET.ParseError) as error:
        print(f"[diff-coverage] {error}", file=sys.stderr)
        sys.exit(2)
