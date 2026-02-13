#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-./.build/arm64-apple-macosx/debug/astation}"
LOG_PATH="${HOME}/Library/Logs/Astation/astation.log"

if [[ ! -x "${APP_PATH}" ]]; then
  echo "Astion binary not found: ${APP_PATH}"
  echo "Build first with: swift build -c debug"
  exit 1
fi

mkdir -p "$(dirname "${LOG_PATH}")"
touch "${LOG_PATH}"

echo "Starting Astation: ${APP_PATH}"
"${APP_PATH}" >/dev/null 2>&1 &
APP_PID=$!

cleanup() {
  if kill -0 "${APP_PID}" 2>/dev/null; then
    kill "${APP_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "App PID: ${APP_PID}"
echo "Please use the menu bar to:"
echo "  1) Start Screen Share (Display...)"
echo "  2) Stop Screen Share"
echo "Waiting for log entries in ${LOG_PATH}..."

wait_for_log() {
  local pattern="$1"
  local timeout="$2"
  local start
  start=$(date +%s)
  while true; do
    if tail -n 200 "${LOG_PATH}" | grep -q "${pattern}"; then
      echo "OK: ${pattern}"
      return 0
    fi
    if [[ $(( $(date +%s) - start )) -ge "${timeout}" ]]; then
      echo "Timeout waiting for: ${pattern}"
      return 1
    fi
    sleep 1
  done
}

wait_for_log "Screen sharing started" 60
wait_for_log "Screen sharing stopped" 60

echo "Smoke test complete."
