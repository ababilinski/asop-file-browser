#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: check-notary-submission-readiness.sh APP_PATH" >&2
}

APP_PATH="${1:-}"
[[ -n "$APP_PATH" && $# -eq 1 ]] || {
  usage
  exit 2
}
[[ -d "$APP_PATH" ]] || {
  echo "Notary submission readiness check failed: missing app bundle: $APP_PATH" >&2
  exit 2
}

SYSPOLICY_CHECK_BIN="${SYSPOLICY_CHECK_BIN:-/usr/bin/syspolicy_check}"
RETRY_DELAY_SECONDS="${SYSPOLICY_CHECK_RETRY_DELAY_SECONDS:-5}"
[[ "$RETRY_DELAY_SECONDS" =~ ^[0-9]+$ ]] || {
  echo "Notary submission readiness check failed: retry delay must be a nonnegative integer." >&2
  exit 2
}

EXPECTED_INTERNAL_XPROTECT='App has failed one or more pre-notarization checks. --------------------------------------------------------------- Internal Xprotect Error Severity: Fatal Full Error: One or more files in your application triggered an Xprotect error. Type: Distribution Error ---------------------------------------------------------------'
RESULT_FILE="$(/usr/bin/mktemp -t asop-syspolicy.XXXXXX)"
trap '/bin/rm -f "$RESULT_FILE"' EXIT

for attempt in 1 2 3; do
  set +e
  "$SYSPOLICY_CHECK_BIN" notary-submission "$APP_PATH" >"$RESULT_FILE" 2>&1
  SYSPOLICY_EXIT_CODE=$?
  set -e

  /bin/cat "$RESULT_FILE"
  if [[ "$SYSPOLICY_EXIT_CODE" -eq 0 ]]; then
    exit 0
  fi

  NORMALIZED_SYSPOLICY_OUTPUT="$(
    /usr/bin/tr '\n' ' ' <"$RESULT_FILE" | /usr/bin/awk '{$1=$1; print}'
  )"
  if [[ "$SYSPOLICY_EXIT_CODE" -ne 70 \
      || "$NORMALIZED_SYSPOLICY_OUTPUT" != "$EXPECTED_INTERNAL_XPROTECT" ]]; then
    exit "$SYSPOLICY_EXIT_CODE"
  fi

  if [[ "$attempt" -lt 3 ]]; then
    /bin/sleep "$((attempt * RETRY_DELAY_SECONDS))"
  fi
done

echo '::warning title=Apple XProtect preflight unavailable::syspolicy_check returned its exact internal XProtect error after three attempts. Continuing to the Apple notary service; publication still requires Accepted status, an issue-free log, stapling, Gatekeeper acceptance, and independent verification.'
