#!/usr/bin/env bash
# Runs deploy.sh against the mock API in each scenario and checks how it ends.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'kill "${MOCK_PID:-0}" 2>/dev/null || true; rm -rf "$WORK"' EXIT
FAILURES=0

start_mock() {
  rm -f "$WORK/port" "$WORK/requests"
  python3 "$HERE/mock_api.py" "$1" "$WORK/port" "$WORK/requests" &
  MOCK_PID=$!
  for _ in $(seq 50); do
    [ -s "$WORK/port" ] && return 0
    sleep 0.1
  done
  echo "the mock API did not start" >&2
  exit 1
}

stop_mock() {
  kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
}

# run_deploy <scenario> [VAR=value...]: runs the action's script; sets STATUS and OUT.
run_deploy() {
  local scenario=$1
  shift
  start_mock "$scenario"
  : >"$WORK/github_output"
  set +e
  OUT=$(env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$WORK/github_output" POLL_SECONDS=0 \
    INPUT_APP=proj-1/app-1 INPUT_PROJECT= INPUT_IMAGE="ghcr.io/acme/web@sha256:$(printf 'ab%.0s' $(seq 32))" \
    INPUT_TOKEN=excali_test_token INPUT_API_URL="http://127.0.0.1:$(cat "$WORK/port")/api" \
    INPUT_COMMIT_SHA=9fceb02d0ae598e95dc970b74767f19372d61af8 INPUT_TIMEOUT=30 "$@" \
    "$HERE/../deploy.sh" 2>&1)
  STATUS=$?
  set -e
  stop_mock
}

check() {
  local name=$1 want_status=$2 want_text=$3
  if { [ "$want_status" = 0 ] && [ "$STATUS" != 0 ]; } || { [ "$want_status" != 0 ] && [ "$STATUS" = 0 ]; }; then
    echo "FAIL $name: exit $STATUS, want $want_status"$'\n'"$OUT"
    FAILURES=$((FAILURES + 1))
  elif [[ "$OUT" != *"$want_text"* ]]; then
    echo "FAIL $name: output lacks '$want_text'"$'\n'"$OUT"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok   $name"
  fi
}

requests() { cat "$WORK/requests" 2>/dev/null || true; }

run_deploy wait-live
check "a deploy the API waits for is live" 0 "Live at https://web.apps.test"
for want in url=https://web.apps.test deploy-id=dep-1 status=succeeded; do
  grep -qx "$want" "$WORK/github_output" || { echo "FAIL outputs lack $want: $(cat "$WORK/github_output")"; FAILURES=$((FAILURES + 1)); }
done

run_deploy wait-live
REQUEST=$(requests | head -n 1)
for want in '"method": "POST"' 'deploy?wait=true&timeout=30' '\"commitSha\":\"9fceb02d0ae598e95dc970b74767f19372d61af8\"' \
  '\"image\":\"ghcr.io/acme/web@sha256:abab' '"auth": "Bearer excali_test_token"'; do
  [[ "$REQUEST" == *"$want"* ]] || { echo "FAIL the deploy request lacks $want: $REQUEST"; FAILURES=$((FAILURES + 1)); }
done

run_deploy wait-failed
check "a failed deploy fails the step with the reason" 1 "never became ready"
run_deploy wait-superseded
check "a superseded deploy fails the step" 1 "superseded"
run_deploy legacy-live
check "an API that does not wait is polled until live" 0 "Live at https://web.apps.test"
run_deploy legacy-failed
check "a polled deploy that fails fails the step" 1 "never became ready"
run_deploy wait-ran-out
check "a wait the API cut short is polled to the end" 0 "Live at https://web.apps.test"
run_deploy edge-cut
check "an answer lost at the edge finds the deploy and follows it" 0 "Live at https://web.apps.test"
run_deploy edge-cut-old-deploy
check "an earlier run's deploy is never taken for this one" 1 "did not complete (504)"
run_deploy refused
check "a refused deploy fails the step with what the API said" 1 "the registry has no such image"
run_deploy api-down UNANSWERED_LIMIT=3
check "an API that stays down fails the step" 1 "did not answer (503)"
run_deploy never-live INPUT_TIMEOUT=2
check "a deploy not live in time fails the step" 1 "was not live within 2 seconds"
run_deploy wait-live INPUT_TOKEN=wrong
check "a token the API refuses fails the step" 1 "unauthenticated"
run_deploy wait-live INPUT_APP=app-1 INPUT_PROJECT=proj-1
check "project and app may be named apart" 0 "Live at"
run_deploy wait-live INPUT_APP="proj-1/app 1"
check "an app that is not an id is refused before any request" 1 "app id must be an app id"
[ -z "$(requests)" ] || { echo "FAIL a refused input still called the API"; FAILURES=$((FAILURES + 1)); }
run_deploy wait-live INPUT_TIMEOUT=soon
check "a timeout that is not seconds is refused" 1 "timeout must be a whole number"
run_deploy wait-live INPUT_COMMIT_SHA=main
check "a commit that is not a sha is refused" 1 "commit-sha must be a full git commit sha"

run_deploy wait-live
if grep -q excali_test_token <<<"$OUT"; then
  echo "FAIL outside GitHub Actions no output line may contain the token"; FAILURES=$((FAILURES + 1))
else
  echo "ok   the token is never printed outside GitHub Actions"
fi
run_deploy wait-live GITHUB_ACTIONS=true
LEAKS=$(grep excali_test_token <<<"$OUT" || true)
if [ "$LEAKS" != "::add-mask::excali_test_token" ] && [ -n "$LEAKS" ]; then
  echo "FAIL on GitHub Actions only the runner's mask command may carry the token: $LEAKS"; FAILURES=$((FAILURES + 1))
else
  echo "ok   on GitHub Actions the token only reaches the runner's mask command"
fi
run_deploy refused
if grep -q excali_test_token <<<"$OUT"; then
  echo "FAIL a failing run printed the token"; FAILURES=$((FAILURES + 1))
else
  echo "ok   a failing run does not print the token"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failed"
  exit 1
fi
echo "all passed"
