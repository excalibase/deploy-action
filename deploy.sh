#!/usr/bin/env bash
# Deploys INPUT_IMAGE to an Excalibase app and waits until it is live.
#
# It asks the API to wait (POST .../deploy?wait=true), which answers once the
# deploy has finished. An API without that answers at once with the started
# deploy, and a wait that is cut short (the API's own bound, the network)
# leaves a deploy to follow; both are then polled until the timeout.
set -euo pipefail

POLL_SECONDS=${POLL_SECONDS:-5}
# Polls that may go unanswered in a row before the step gives up.
UNANSWERED_LIMIT=${UNANSWERED_LIMIT:-6}
ID_PATTERN='^[A-Za-z0-9_-]{1,64}$'

fail() {
  echo "::error::$*" >&2
  exit 1
}

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >>"$GITHUB_OUTPUT"
  fi
}

# resolve_app sets PROJECT and APP from INPUT_APP (project/app) or INPUT_PROJECT + INPUT_APP.
resolve_app() {
  if [[ "$INPUT_APP" == */* ]]; then
    [ -z "${INPUT_PROJECT:-}" ] || fail "name the project once: app as <project>/<app>, or project and app apart"
    PROJECT=${INPUT_APP%%/*}
    APP=${INPUT_APP#*/}
  else
    PROJECT=${INPUT_PROJECT:-}
    APP=$INPUT_APP
  fi
  [[ "$PROJECT" =~ $ID_PATTERN ]] || fail "app must be <project id>/<app id> (or set project): got '$INPUT_APP'"
  [[ "$APP" =~ $ID_PATTERN ]] || fail "the app id must be an app id: got '$APP'"
}

check_inputs() {
  command -v curl >/dev/null || fail "curl is required"
  command -v jq >/dev/null || fail "jq is required"
  [ -n "${INPUT_IMAGE:-}" ] || fail "image is required"
  [ -n "${INPUT_TOKEN:-}" ] || fail "token is required: a write token bound to the project, from a secret"
  [[ "${INPUT_TIMEOUT:-}" =~ ^[1-9][0-9]{0,5}$ ]] || fail "timeout must be a whole number of seconds"
  [[ "${INPUT_COMMIT_SHA:-}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})?$ ]] || fail "commit-sha must be a full git commit sha"
  [[ "${INPUT_API_URL:-}" =~ ^https?://[^[:space:]]+$ ]] || fail "api-url must be an http(s) URL"
  # Only the GitHub runner consumes this command; any other CI would log the token.
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::add-mask::$INPUT_TOKEN"
  fi
}

# api METHOD PATH [BODY]: sets CODE (000 when no answer) and BODY from the API.
api() {
  local answer
  local args=(-sS -X "$1" "$APP_API$2" -H "Authorization: Bearer $INPUT_TOKEN"
    --max-time "$(remaining_with_margin)" -w '\n%{http_code}')
  if [ $# -ge 3 ]; then
    args+=(-H "Content-Type: application/json" --data-binary "$3")
  fi
  answer=$(curl "${args[@]}" 2>&1) || true
  CODE=${answer##*$'\n'}
  BODY=${answer%$'\n'*}
  [[ "$CODE" =~ ^[0-9]{3}$ ]] || { BODY=$answer; CODE=000; }
}

remaining() {
  echo $((DEADLINE - SECONDS))
}

# The wait for the deploy itself plus a minute for the answer to arrive.
remaining_with_margin() {
  local left
  left=$(remaining)
  echo $((left > 0 ? left + 60 : 60))
}

field() {
  jq -r "$1 // empty" <<<"$BODY" 2>/dev/null || true
}

is_json() {
  jq -e 'type == "object"' <<<"$BODY" >/dev/null 2>&1
}

start_deploy() {
  local body
  body=$(jq -cn --arg image "$INPUT_IMAGE" --arg sha "$INPUT_COMMIT_SHA" \
    '{image: $image} + (if $sha == "" then {} else {commitSha: $sha} end)')
  echo "Deploying $INPUT_IMAGE to $PROJECT/$APP"
  api POST "/deploy?wait=true&timeout=$INPUT_TIMEOUT" "$body"
}

# find_started_deploy recovers the deploy when the answer to the POST was
# lost: this commit and image, created since the step began (a minute's slack
# for clock skew), so an earlier run's deploy is never taken for this one.
find_started_deploy() {
  [ -n "$INPUT_COMMIT_SHA" ] || return 1
  api GET "/deploys?limit=20"
  [ "$CODE" = 200 ] || return 1
  DEPLOY_ID=$(jq -r --arg sha "$INPUT_COMMIT_SHA" --arg image "$INPUT_IMAGE" --argjson since "$((STARTED_AT - 60))" '
    def epoch: try (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch 0;
    map(select(.commitSha == $sha and (.imageRef == $image or .image == $image) and ((.createdAt // "") | epoch) >= $since))
    | first | .id // empty' <<<"$BODY" 2>/dev/null || true)
  [ -n "$DEPLOY_ID" ]
}

# poll follows DEPLOY_ID until it finishes or the timeout; leaves its last answer in BODY.
poll() {
  local unanswered=0 status
  echo "Waiting for deploy $DEPLOY_ID to be live"
  while [ "$(remaining)" -gt 0 ]; do
    sleep "$POLL_SECONDS"
    api GET "/deploys/$DEPLOY_ID"
    case "$CODE" in
      200) unanswered=0 ;;
      000 | 5??)
        unanswered=$((unanswered + 1))
        [ "$unanswered" -lt "$UNANSWERED_LIMIT" ] || fail "the API did not answer ($CODE): $BODY"
        continue
        ;;
      *) fail "polling deploy $DEPLOY_ID was refused ($CODE): $BODY" ;;
    esac
    status=$(field .status)
    case "$status" in
      succeeded | failed | superseded) return 0 ;;
      pending | rolling) ;;
      *) fail "unexpected answer: $BODY" ;;
    esac
  done
  fail "deploy $DEPLOY_ID was not live within $INPUT_TIMEOUT seconds; it carries on: see the app's pipeline in Studio"
}

finish() {
  local status url
  status=$(field .status)
  url=$(field .url)
  output deploy-id "$DEPLOY_ID"
  output status "$status"
  output url "$url"
  case "$status" in
    succeeded)
      echo "Live at $url"
      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "Deployed \`$INPUT_IMAGE\` to $PROJECT/$APP: live at $url" >>"$GITHUB_STEP_SUMMARY"
      fi
      ;;
    failed) fail "deploy $DEPLOY_ID failed: $(field .failureReason)" ;;
    *) fail "deploy $DEPLOY_ID was $status: a newer deploy of the app replaced it" ;;
  esac
}

# follow_answer acts on the answer to the POST until the deploy has finished.
follow_answer() {
  DEPLOY_ID=""
  if is_json; then
    DEPLOY_ID=$(field .id)
  fi
  case "$CODE" in
    200 | 409 | 422 | 202 | 504)
      # A deploy in the answer: finished (200, 409, 422), started on an API
      # that does not wait (202), or still running when the wait ended (504).
      if [ -n "$DEPLOY_ID" ] && [ -n "$(field .status)" ]; then
        [[ "$CODE" =~ ^(202|504)$ ]] && poll
        return 0
      fi
      ;;
  esac
  if [ "$CODE" = 000 ] || { [[ "$CODE" =~ ^50[24]$ ]] && ! is_json; }; then
    # No answer, or the edge's: the deploy may have started all the same.
    local code=$CODE body=$BODY
    find_started_deploy || fail "the deploy request did not complete ($code): $body"
    poll
    return 0
  fi
  local reason
  reason=$(field .error)
  fail "the deploy was refused ($CODE): ${reason:-$BODY}"
}

main() {
  resolve_app
  check_inputs
  APP_API="${INPUT_API_URL%/}/projects/$PROJECT/apps/$APP"
  STARTED_AT=$(date +%s)
  DEADLINE=$((SECONDS + INPUT_TIMEOUT))
  start_deploy
  follow_answer
  finish
}

main "$@"
