#!/usr/bin/env bash

set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBSITE_DIR="$ROOT_DIR/services/Roblox/Roblox.Website"
ADMIN_DIR="$ROOT_DIR/services/admin"
ASSET_VALIDATION_DIR="$ROOT_DIR/services/AssetValidationServiceV2"
FRONTEND_DIR="$ROOT_DIR/services/2016-roblox-main"
LOG_DIR="${TMPDIR:-/tmp}/economy-simulator-logs"
INCLUDE_FRONTEND=1
START_SUPPORT_SERVICES=1

for arg in "$@"; do
  case "$arg" in
    --no-frontend)
      INCLUDE_FRONTEND=0
      ;;
    --no-support-services)
      START_SUPPORT_SERVICES=0
      ;;
    --help|-h)
      cat <<HELP
Usage: ./run-all.sh [options]

Options:
  --no-frontend         Do not run services/2016-roblox-main dev server
  --no-support-services Do not attempt to start PostgreSQL/Redis services
  -h, --help            Show this help
HELP
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[error] Missing command: $cmd"
    return 1
  fi
  return 0
}

start_service_if_possible() {
  local service_name="$1"
  local os_name
  os_name="$(uname -s)"

  if [[ $START_SUPPORT_SERVICES -ne 1 ]]; then
    return 0
  fi

  if [[ "$os_name" == "Linux" ]] && command -v systemctl >/dev/null 2>&1; then
    sudo systemctl start "$service_name" >/dev/null 2>&1 || true
    return 0
  fi

  if [[ "$os_name" == "Linux" ]] && command -v service >/dev/null 2>&1; then
    sudo service "$service_name" start >/dev/null 2>&1 || true
    return 0
  fi

  if [[ "$os_name" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    if [[ "$service_name" == "postgresql" ]]; then
      brew services start postgresql@14 >/dev/null 2>&1 || brew services start postgresql >/dev/null 2>&1 || true
      return 0
    fi
    if [[ "$service_name" == "redis-server" ]]; then
      brew services start redis >/dev/null 2>&1 || true
      return 0
    fi
  fi
}

mkdir -p "$LOG_DIR"

if [[ ! -f "$WEBSITE_DIR/appsettings.json" ]]; then
  echo "[error] Missing $WEBSITE_DIR/appsettings.json"
  echo "Run ./setup.sh first."
  exit 1
fi

if [[ ! -f "$ROOT_DIR/services/api/config.json" ]]; then
  echo "[warn] Missing $ROOT_DIR/services/api/config.json (required for API migrations/setup workflows)."
fi

if [[ $START_SUPPORT_SERVICES -eq 1 && $(id -u) -eq 0 ]]; then
  echo "[warn] Running as root is not recommended."
fi

if [[ $START_SUPPORT_SERVICES -eq 1 ]]; then
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    echo "[info] Attempting to start PostgreSQL and Redis via Homebrew services."
    start_service_if_possible postgresql
    start_service_if_possible redis-server
  elif command -v sudo >/dev/null 2>&1; then
    echo "[info] Attempting to start PostgreSQL and Redis services."
    start_service_if_possible postgresql
    start_service_if_possible redis-server
  else
    echo "[warn] Could not auto-start PostgreSQL/Redis services on this OS."
  fi
fi

require_command dotnet || exit 1
require_command npm || exit 1
require_command go || exit 1

if [[ ! -d "$ADMIN_DIR/node_modules" ]]; then
  echo "[warn] $ADMIN_DIR/node_modules missing. Run ./setup.sh first."
fi

if [[ $INCLUDE_FRONTEND -eq 1 && ! -f "$FRONTEND_DIR/config.json" ]]; then
  echo "[warn] Missing $FRONTEND_DIR/config.json. Run ./setup.sh first or use --no-frontend."
fi

declare -a PIDS=()
declare -a NAMES=()
declare -a LOGS=()

start_process() {
  local name="$1"
  local dir="$2"
  local cmd="$3"
  local log_file="$LOG_DIR/${name}.log"

  echo "[info] Starting $name..."
  (
    cd "$dir"
    bash -lc "$cmd"
  ) >"$log_file" 2>&1 &

  PIDS+=("$!")
  NAMES+=("$name")
  LOGS+=("$log_file")
}

start_process "website" "$WEBSITE_DIR" "dotnet run"
start_process "admin" "$ADMIN_DIR" "npm run dev"
start_process "asset-validation" "$ASSET_VALIDATION_DIR" "go run main.go"

if [[ $INCLUDE_FRONTEND -eq 1 ]]; then
  start_process "frontend" "$FRONTEND_DIR" "npm run dev"
fi

cleanup() {
  echo
  echo "[info] Stopping services..."
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done
  wait >/dev/null 2>&1 || true
  echo "[ok] All processes stopped."
}

trap cleanup EXIT INT TERM

echo
echo "Services are starting. Logs:"
for i in "${!NAMES[@]}"; do
  echo "- ${NAMES[$i]}: ${LOGS[$i]}"
done

echo
echo "Access points:"
echo "- Website:            http://localhost:5000/"
echo "- Website admin:      http://localhost:5000/admin/"
echo "- Website API proxy:  http://localhost:5000/apisite/"
echo "- Website Swagger:    http://localhost:5000/swagger"
if [[ $INCLUDE_FRONTEND -eq 1 ]]; then
  echo "- Frontend:           http://localhost:3000/"
fi
echo "- Asset validator:    http://localhost:4300/"

echo
echo "Press Ctrl+C to stop all services."

sleep 3
for i in "${!PIDS[@]}"; do
  if ! kill -0 "${PIDS[$i]}" >/dev/null 2>&1; then
    echo "[error] ${NAMES[$i]} exited early. Check log: ${LOGS[$i]}"
    exit 1
  fi
done

if wait -n >/dev/null 2>&1; then
  :
else
  echo "[error] A service stopped unexpectedly. Check logs in $LOG_DIR"
  exit 1
fi
