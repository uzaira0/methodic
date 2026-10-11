"""Install an operator-owned reconciliation schedule without replacing other cron jobs."""

import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess

from .common import run
from .receipts import write_text

INTERVAL_MINUTES = 15
STOP_MARKER = ".chronicle-stopped"
RECOVERY_PHASE = "migration-started"
RECOVERY_FILE = "recovery.json"
ENABLED_ENV = "CHRONICLE_RECONCILE_ENABLED"
UPDATE_LOG = "reconcile.update.log"


def is_enabled():
    return os.environ.get(ENABLED_ENV, "true") == "true"


def preflight():
    if not is_enabled():
        return
    if platform.system() != "Linux":
        raise ValueError("automatic reconciliation requires a Linux operator crontab")
    if any(shutil.which(tool) is None for tool in ("crontab", "logger", "systemctl")):
        raise ValueError("reconciliation requires crontab, logger and systemctl; install cron/cronie or explicitly disable reconciliation")
    if not any(run(["systemctl", "is-enabled", service], quiet=True).returncode == 0
               and run(["systemctl", "is-active", service], quiet=True).returncode == 0
               for service in ("cron", "crond")):
        raise ValueError("reconciliation requires an enabled, active cron/crond service")


def check_mutations(state, launcher, allow_forward=False):
    for name in (".chronicle-restore.lock", ".chronicle-upgrade.lock", ".chronicle-secret-rotation"):
        marker = Path(state) / name
        if not os.path.lexists(marker):
            continue
        if allow_forward and name == ".chronicle-upgrade.lock" and os.environ.get("CHRONICLE_RECONCILE_RUN") != "true":
            import json
            try:
                recovery = json.loads((marker / RECOVERY_FILE).read_text())
                if recovery["owner"] == str(Path(launcher).resolve()) and recovery["phase"] == RECOVERY_PHASE:
                    continue
            except (OSError, ValueError, KeyError):
                pass
        raise ValueError(f"incomplete operation at {marker}; use its recorded recovery owner or reviewed restore")


def crontab_without_project(project):
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", project):
        raise ValueError("invalid reconciliation project")
    current = run(["crontab", "-l"], capture=True, stderr=subprocess.PIPE,
                  env=dict(os.environ, LC_ALL="C"))
    if current.returncode and (current.returncode != 1 or "no crontab" not in current.stderr.lower()):
        raise ValueError("could not read the operator crontab")
    marker = "# chronicle-reconcile:" + project
    return [line for line in current.stdout.splitlines() if not line.endswith(marker)], marker


def uninstall(state, project):
    write_text(Path(state) / STOP_MARKER, "uninstalled reconciliation\n")
    if shutil.which("crontab"):
        lines, _ = crontab_without_project(project)
        run(["crontab", "-"], input="\n".join(lines) + "\n", check=True)
    (Path(state) / "reconcile.sh").unlink(missing_ok=True)


def install(launcher, state, project, update_only=False):
    from .release import UPDATE_AVAILABLE_EXIT, set_current_owner
    launcher, state = Path(launcher).resolve(), Path(state).resolve()
    set_current_owner(launcher.parent, state)
    if not is_enabled():
        return
    script = state / "reconcile.sh"
    if update_only and not script.exists():
        return
    if platform.system() != "Linux":
        raise ValueError("automatic reconciliation requires a Linux operator crontab")
    if not update_only and any(shutil.which(tool) is None for tool in ("crontab", "logger")):
        raise ValueError("reconciliation requires crontab and logger on PATH")
    if script.is_symlink():
        raise ValueError("unsafe reconciliation launcher")
    for path in (launcher, state):
        if any(char in str(path) for char in "\r\n%"):
            raise ValueError("reconciliation path contains cron control characters")
    quote = shlex.quote
    docker_environment = "\n".join(f"export {key}={quote(os.environ[key])}"
                                   for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH")
                                   if key in os.environ)
    content = f'''#!/usr/bin/env bash
set -euo pipefail
umask 077
export PATH={quote(os.environ.get("PATH", "/usr/bin:/bin"))}
{docker_environment}
cd {quote(str(launcher.parent))}
export PYTHONDONTWRITEBYTECODE=1 PYTHONPATH={quote(str(launcher.parent))}
if [[ "${{1:-}}" == --check-updates ]]; then
  update_status=0
  ./chronicle update --check >{quote(str(state / UPDATE_LOG))} 2>&1 || update_status=$?
  case "$update_status" in
    0) exit 0 ;;
    {UPDATE_AVAILABLE_EXIT}) logger -t chronicle 'Chronicle update available; run ./chronicle update from the active selfhost directory' ;;
    *) logger -t chronicle 'Update check failed; inspect the private state {UPDATE_LOG}'; exit 1 ;;
  esac
  exit 0
fi
exec python3 -m chronicle_ops operation-lock --state {quote(str(state))} --nonblocking -- bash -s <<'RECONCILE'
[[ ! -e {quote(str(state / STOP_MARKER))} ]] || exit 0
if ! (
  up_status=0
  CHRONICLE_RECONCILE_RUN=true ./chronicle up || up_status=$?
  ./chronicle doctor && ((up_status == 0))
) >{quote(str(state / "reconcile.log"))} 2>&1; then
  logger -t chronicle 'Reconciliation failed; inspect the private state reconcile.log'
  exit 1
fi
RECONCILE
'''
    lines, marker = crontab_without_project(project)
    write_text(script, content)
    script.chmod(0o700)
    command = quote(str(script)) + " " + marker
    lines += ["@reboot " + command, f"*/{INTERVAL_MINUTES} * * * * " + command]
    if (launcher.parent.parent / "release-manifest.json").is_file():
        lines.append("0 6 * * * " + quote(str(script)) + " --check-updates " + marker)
    run(["crontab", "-"], input="\n".join(lines) + "\n", check=True)


def complete_recovery():
    from .common import acquire_operation_lock, release_operation_lock
    import json
    state = Path(os.environ["CHRONICLE_OPS_STATE"])
    marker = state / ".chronicle-upgrade.lock"
    if not marker.exists():
        return
    descriptor = acquire_operation_lock(state)
    try:
        if not marker.exists():
            return
        check_mutations(state, Path.cwd(), allow_forward=True)
        recovery = json.loads((marker / RECOVERY_FILE).read_text())
        if recovery["owner"] != str(Path.cwd().resolve()):
            raise ValueError("only the recorded forward owner can finish recovery")
        preflight()
        install(Path.cwd() / "chronicle", state, os.environ["CHRONICLE_OPS_PROJECT"])
        (marker / RECOVERY_FILE).unlink()
        marker.rmdir()
    finally:
        release_operation_lock(descriptor)
