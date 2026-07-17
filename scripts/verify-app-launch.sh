#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: verify-app-launch.sh APP_PATH [options]

Options:
  --launch-timeout SECONDS  Time allowed for Launch Services to start the app.
                            Defaults to 20 seconds.
  --stability SECONDS       Time the launched app must remain running.
                            Defaults to 5 seconds.
USAGE
}

fail() {
  echo "App launch verification failed: $*" >&2
  exit 1
}

APP_PATH="${1:-}"
[[ -n "$APP_PATH" ]] || {
  usage >&2
  exit 2
}
shift

LAUNCH_TIMEOUT_SECONDS=20
STABILITY_SECONDS=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch-timeout)
      [[ $# -ge 2 ]] || fail "--launch-timeout needs a value."
      LAUNCH_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --stability)
      [[ $# -ge 2 ]] || fail "--stability needs a value."
      STABILITY_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ "$LAUNCH_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || fail "--launch-timeout must be a positive whole number."
[[ "$STABILITY_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || fail "--stability must be a positive whole number."
[[ -d "$APP_PATH" ]] || fail "Missing app bundle: $APP_PATH"

# Launch Services resolves symlinked build directories before starting the
# executable. Match that physical path when identifying the new process.
APP_PATH="$(cd -P "$(dirname "$APP_PATH")" && pwd -P)/$(basename "$APP_PATH")"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "Missing app Info.plist: $INFO_PLIST"

APP_EXECUTABLE_NAME="$(
  /usr/bin/plutil -extract CFBundleExecutable raw -o - "$INFO_PLIST" 2>/dev/null
)"
[[ -n "$APP_EXECUTABLE_NAME" ]] || fail "CFBundleExecutable is empty."
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE_NAME"
[[ -x "$APP_EXECUTABLE" ]] || fail "Missing executable: $APP_EXECUTABLE"

APP_PID=""
LAUNCH_STARTED=false

find_app_pid() {
  /bin/ps -axo pid=,command= | /usr/bin/awk -v executable="$APP_EXECUTABLE" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
      if (!found && ($0 == executable || index($0, executable " ") == 1)) {
        print pid
        found = 1
      }
    }
  '
}

stop_launched_app() {
  local pid_to_stop="$APP_PID"
  local attempt

  set +e
  if [[ -z "$pid_to_stop" && "$LAUNCH_STARTED" == true ]]; then
    pid_to_stop="$(find_app_pid)"
  fi
  if [[ -z "$pid_to_stop" ]] || ! /bin/kill -0 "$pid_to_stop" 2>/dev/null; then
    return 0
  fi

  /bin/kill -TERM "$pid_to_stop" 2>/dev/null
  for ((attempt = 0; attempt < 20; attempt += 1)); do
    if ! /bin/kill -0 "$pid_to_stop" 2>/dev/null; then
      return 0
    fi
    /bin/sleep 0.25
  done
  /bin/kill -KILL "$pid_to_stop" 2>/dev/null
  return 0
}
trap stop_launched_app EXIT

EXISTING_PID="$(find_app_pid)"
[[ -z "$EXISTING_PID" ]] \
  || fail "The same app bundle is already running as process $EXISTING_PID."

if ! OPEN_OUTPUT="$(/usr/bin/open -n "$APP_PATH" 2>&1)"; then
  [[ -z "$OPEN_OUTPUT" ]] || echo "$OPEN_OUTPUT" >&2
  fail "Launch Services could not open $APP_PATH."
fi
LAUNCH_STARTED=true

for ((attempt = 0; attempt < LAUNCH_TIMEOUT_SECONDS * 4; attempt += 1)); do
  APP_PID="$(find_app_pid)"
  [[ -z "$APP_PID" ]] || break
  /bin/sleep 0.25
done
[[ -n "$APP_PID" ]] \
  || fail "The app process did not appear within $LAUNCH_TIMEOUT_SECONDS seconds."

for ((attempt = 0; attempt < STABILITY_SECONDS * 4; attempt += 1)); do
  /bin/kill -0 "$APP_PID" 2>/dev/null \
    || fail "The app exited before the $STABILITY_SECONDS-second stability check finished."
  /bin/sleep 0.25
done

echo "Opened $APP_PATH as process $APP_PID; it remained running for $STABILITY_SECONDS seconds."
