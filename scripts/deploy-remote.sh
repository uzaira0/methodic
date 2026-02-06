#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
One-click remote deploy for Chronicle.
Usage: scripts/deploy-remote.sh [--setup|--update|--logs] <host>

Options:
  --setup   Install Docker if missing, then deploy (may prompt for sudo).
  --update  Pull and restart only (no file sync).
  --logs    Stream logs (no setup or sync).

Environment:
  DEPLOY_HOST          default host if not provided
  DEPLOY_DIR           remote deploy dir (default ~/methodic)
  GITHUB_TOKEN         required for pull/deploy
  GITHUB_USER          ghcr.io username (or set GITHUB_ACTOR)
  SSH_OPTS             extra ssh options (e.g. -i ~/.ssh/id_rsa)
  DEPLOY_LOGS_SERVICE  optional compose service for --logs
USAGE
}

log() { printf '%s\n' "$*"; }

DO_SETUP=0
DO_UPDATE=0
DO_LOGS=0
HOST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --setup) DO_SETUP=1 ;;
    --update) DO_UPDATE=1 ;;
    --logs) DO_LOGS=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) log "Unknown option: $1"; usage; exit 1 ;;
    *) [ -z "$HOST" ] && HOST="$1" || { log "Unexpected argument: $1"; usage; exit 1; } ;;
  esac
  shift
done

HOST="${HOST:-${DEPLOY_HOST:-}}"
[ -z "$HOST" ] && { log "Missing host."; usage; exit 1; }

[ "$DO_LOGS" -eq 1 ] && { [ "$DO_SETUP" -eq 1 ] || [ "$DO_UPDATE" -eq 1 ]; } && { log "--logs cannot be combined with --setup or --update."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_DOCKER_DIR="$REPO_ROOT/docker"

[ ! -d "$LOCAL_DOCKER_DIR" ] && { log "Missing docker/ directory at $LOCAL_DOCKER_DIR"; exit 1; }

DEPLOY_DIR="${DEPLOY_DIR:-~/methodic}"
SSH_OPTS="${SSH_OPTS:-}"

if [ "$DO_LOGS" -eq 0 ]; then
  GITHUB_USER="${GITHUB_USER:-${GITHUB_ACTOR:-}}"
  [ -z "${GITHUB_TOKEN:-}" ] && { log "GITHUB_TOKEN is required for ghcr.io auth."; exit 1; }
  [ -z "$GITHUB_USER" ] && { log "GITHUB_USER (or GITHUB_ACTOR) is required for ghcr.io auth."; exit 1; }
fi

ssh_run() {
  local tty_opt="$1"; shift
  if [ -n "$tty_opt" ]; then
    ssh $tty_opt $SSH_OPTS "$HOST" "$@"
  else
    ssh $SSH_OPTS "$HOST" "$@"
  fi
}

sync_files() {
  log "Syncing docker/ to $HOST:$DEPLOY_DIR"
  ssh_run "" "mkdir -p $DEPLOY_DIR"
  if command -v rsync >/dev/null 2>&1 && ssh_run "" "command -v rsync >/dev/null 2>&1"; then
    local rsync_ssh="ssh"; [ -n "$SSH_OPTS" ] && rsync_ssh="ssh $SSH_OPTS"
    rsync -az -e "$rsync_ssh" "$LOCAL_DOCKER_DIR/" "$HOST:$DEPLOY_DIR/docker/"
  else
    scp $SSH_OPTS -r "$LOCAL_DOCKER_DIR" "$HOST:$DEPLOY_DIR/"
  fi
  [ -f "$REPO_ROOT/.env" ] && { log "Copying .env"; scp $SSH_OPTS "$REPO_ROOT/.env" "$HOST:$DEPLOY_DIR/.env"; }
}

remote_script() {
  local mode="$1" tty_opt="$2" need_token="$3"
  local env_prefix="DEPLOY_DIR=$DEPLOY_DIR MODE=$mode"
  [ "$need_token" -eq 1 ] && env_prefix="$env_prefix GITHUB_USER=$(printf '%q' "$GITHUB_USER") GITHUB_TOKEN=$(printf '%q' "$GITHUB_TOKEN")"
  [ -n "${DEPLOY_LOGS_SERVICE:-}" ] && env_prefix="$env_prefix DEPLOY_LOGS_SERVICE=$(printf '%q' "$DEPLOY_LOGS_SERVICE")"
  
  ssh_run "$tty_opt" "$env_prefix bash -s" <<'REMOTE_EOF'
set -euo pipefail
MODE="${MODE:-deploy}"
DEPLOY_DIR="${DEPLOY_DIR:-~/methodic}"
[[ "$DEPLOY_DIR" == "~"* ]] && DEPLOY_DIR="${DEPLOY_DIR/#\~/$HOME}"
COMPOSE_FILE="docker-compose.prod.yml"

ensure_docker() {
  command -v docker >/dev/null 2>&1 || { echo "Docker not found. Run with --setup."; exit 1; }
  DOCKER="docker"
  docker info >/dev/null 2>&1 || { command -v sudo >/dev/null 2>&1 && DOCKER="sudo docker" || { echo "Docker requires elevated privileges."; exit 1; }; }
}

ensure_compose() {
  if $DOCKER compose version >/dev/null 2>&1; then COMPOSE="$DOCKER compose"
  elif command -v docker-compose >/dev/null 2>&1; then [ "$DOCKER" = "sudo docker" ] && COMPOSE="sudo docker-compose" || COMPOSE="docker-compose"
  else echo "Docker Compose not found. Run with --setup."; exit 1; fi
}

setup_docker() {
  command -v docker >/dev/null 2>&1 && { echo "Docker already installed."; return 0; }
  SUDO=""; [ "$(id -u)" -ne 0 ] && { command -v sudo >/dev/null 2>&1 && SUDO="sudo" || { echo "sudo required."; exit 1; }; }
  if command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -y && $SUDO apt-get install -y docker.io docker-compose-plugin
  elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y docker docker-compose
  elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y docker docker-compose
  elif command -v apk >/dev/null 2>&1; then $SUDO apk add --no-cache docker docker-cli-compose
  else echo "Unsupported package manager."; exit 1; fi
  command -v systemctl >/dev/null 2>&1 && $SUDO systemctl enable --now docker || $SUDO service docker start
  [ "$(id -u)" -ne 0 ] && getent group docker >/dev/null 2>&1 && ! id -nG "$USER" | grep -qw docker && $SUDO usermod -aG docker "$USER" && echo "Added to docker group; re-login may be required."
}

deploy_stack() {
  [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_USER:-}" ] && { echo "GITHUB_TOKEN and GITHUB_USER required."; exit 1; }
  [ ! -d "$DEPLOY_DIR/docker" ] && { echo "Missing $DEPLOY_DIR/docker."; exit 1; }
  ensure_docker; ensure_compose
  cd "$DEPLOY_DIR/docker"
  [ ! -f "$COMPOSE_FILE" ] && { echo "Missing $COMPOSE_FILE."; exit 1; }
  [ ! -f ".env" ] && echo "Warning: .env not found."
  echo "$GITHUB_TOKEN" | $DOCKER login ghcr.io -u "$GITHUB_USER" --password-stdin
  $COMPOSE -f "$COMPOSE_FILE" pull
  $COMPOSE -f "$COMPOSE_FILE" up -d
  [ ! -f "certs/fullchain.pem" ] && echo "SSL certs missing; run ./init-ssl.sh"
}

stream_logs() {
  [ ! -d "$DEPLOY_DIR/docker" ] && { echo "Missing $DEPLOY_DIR/docker."; exit 1; }
  ensure_docker; ensure_compose
  cd "$DEPLOY_DIR/docker"
  [ -n "${DEPLOY_LOGS_SERVICE:-}" ] && $COMPOSE -f "$COMPOSE_FILE" logs -f "$DEPLOY_LOGS_SERVICE" || $COMPOSE -f "$COMPOSE_FILE" logs -f
}

case "$MODE" in
  setup) setup_docker ;;
  deploy|update) deploy_stack ;;
  logs) stream_logs ;;
  *) echo "Unknown mode: $MODE"; exit 1 ;;
esac
REMOTE_EOF
}

[ "$DO_LOGS" -eq 1 ] && { remote_script "logs" "" 0; exit 0; }
[ "$DO_SETUP" -eq 1 ] && remote_script "setup" "-t" 0
{ [ "$DO_UPDATE" -eq 0 ] || [ "$DO_SETUP" -eq 1 ]; } && sync_files
remote_script "deploy" "" 1
