#!/usr/bin/env bash
# review-command.sh — parses a `/review …` PR comment into a run decision.
# Pure function of its env; unit-tested in tests/review_command_test.sh.
#
# The code review always runs and scales its own depth (review-scan decides), so
# there is no token to turn it off and none to deepen it. Only the browser tester
# is opt-in.
#
# In  (env): CMD_BODY (comment body or the `command` input), CMD_TRIGGER, CMD_EVENT
# Out (KEY=value on stdout, ready for $GITHUB_OUTPUT):
#   action=run|help|unknown|ignore   run | post the menu | bad token, post the menu | not for us
#   run_functional=true|false        browser tester
#   force_deep=true|false            accepted, ignored downstream (review-scan self-scales)
#   passes=<normalized tokens>       for logs
#   message=<single-line reply>      help/unknown, and the `native` removal notice
#
# NOT the authorization gate — that is the job's `if:` on author_association, so an
# outsider's comment never claims a runner. Do not move it in here.

set -uo pipefail

BODY="${CMD_BODY:-}"
TRIGGER="${CMD_TRIGGER:-/review}"
EVENT="${CMD_EVENT:-}"

emit() {
  # $1 action, $2 run_functional, $3 force_deep, $4 passes, $5 message
  printf 'action=%s\nrun_functional=%s\nforce_deep=%s\npasses=%s\nmessage=%s\n' \
    "$1" "$2" "$3" "$4" "$5"
}
help_msg() {
  printf '%s' "Comment \`$TRIGGER code\` (code review) or \`$TRIGGER functional\` (+ browser test), or \`$TRIGGER all\` for both — combine them in ONE comment; separate comments queue up and post separate reviews. The reviewer scales its own depth, so there is nothing to tune. \`native\` and \`deep\` are accepted but do nothing."
}

# `native` ran Anthropic's `code-review` plugin as a second opinion in-session.
# The pass is gone (see docs/adr/0003). The TOKEN stays accepted so a typed
# \`$TRIGGER native\` still gets a review instead of the unknown-option menu.
NATIVE_NOTE="The \`native\` pass has been removed; running the normal code review."
native_note=""

# First line only, and only when the body starts with the trigger — otherwise a
# comment quoting the docs would trigger real runs.
FIRST_LINE=${BODY%%$'\n'*}
FIRST_LINE=${FIRST_LINE#"${FIRST_LINE%%[![:space:]]*}"}   # ltrim
FIRST_LINE=${FIRST_LINE%$'\r'}                            # CRLF-safe

# Manual dispatch with no command: the click IS the opt-in, and a menu posted to
# nobody would be a dead end.
if [ "$EVENT" = "workflow_dispatch" ] && [ -z "${FIRST_LINE//[[:space:]]/}" ]; then
  emit "run" "false" "false" "code" ""
  exit 0
fi

case "$FIRST_LINE" in
  "$TRIGGER") ARGS="" ;;
  "$TRIGGER "*) ARGS="${FIRST_LINE#"$TRIGGER" }" ;;
  *)
    emit "ignore" "false" "false" "" "Not a $TRIGGER command."
    exit 0
    ;;
esac

run_functional=false
force_deep=false
passes=""

add_pass() {
  case " $passes " in *" $1 "*) return 0 ;; esac
  passes="${passes:+$passes }$1"
}

for raw in $ARGS; do
  # Tolerate "code, functional." and `backticks` — this is typed by hand.
  tok=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '`,.;')
  [ -z "$tok" ] && continue
  case "$tok" in
    code|judges|judge)             add_pass code ;;
    functional|browser|e2e|smoke)  run_functional=true; add_pass functional ;;
    # Removed pass, still a valid token: it means "a code review, please".
    native|anthropic|plugin)       native_note="$NATIVE_NOTE"; add_pass code ;;
    all|everything)                run_functional=true
                                   add_pass code; add_pass functional ;;
    deep|full)                     force_deep=true;     add_pass deep ;;
    help|\?)
      emit "help" "false" "false" "" "$(help_msg)"
      exit 0
      ;;
    *)
      emit "unknown" "false" "false" "" "Unknown option \`$tok\`. $(help_msg)"
      exit 0
      ;;
  esac
done

# Bare `/review` prints the menu rather than guessing which pass you meant.
if [ -z "$passes" ]; then
  emit "help" "false" "false" "" "$(help_msg)"
  exit 0
fi

# The code review always runs, so `code` heads the list however it was phrased.
rest=""
for p in $passes; do [ "$p" = code ] || rest="${rest:+$rest }$p"; done
passes="code${rest:+ $rest}"

emit "run" "$run_functional" "$force_deep" "$passes" "$native_note"
