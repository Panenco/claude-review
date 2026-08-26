#!/usr/bin/env bash
# review-command.sh — parses a `/review …` PR comment into a run decision.
# Pure function of its env; unit-tested in tests/review_command_test.sh.
#
# The judges always run, and review-plan.sh still picks their depth. Only the two
# expensive add-ons are opt-in, which is why there is no token to turn judges off.
#
# In  (env): CMD_BODY (comment body or the `command` input), CMD_TRIGGER, CMD_EVENT
# Out (KEY=value on stdout, ready for $GITHUB_OUTPUT):
#   action=run|help|unknown|ignore   run | post the menu | bad token, post the menu | not for us
#   run_functional=true|false        browser tester
#   native_review=on|off             Anthropic's code-review plugin
#   force_deep=true|false            force review_level=full (as the deep-review label does)
#   passes=<normalized tokens>       for logs
#   message=<single-line reply>      help/unknown only
#
# NOT the authorization gate — that is the job's `if:` on author_association, so an
# outsider's comment never claims a runner. Do not move it in here.

set -uo pipefail

BODY="${CMD_BODY:-}"
TRIGGER="${CMD_TRIGGER:-/review}"
EVENT="${CMD_EVENT:-}"

emit() {
  # $1 action, $2 run_functional, $3 native_review, $4 force_deep, $5 passes, $6 message
  printf 'action=%s\nrun_functional=%s\nnative_review=%s\nforce_deep=%s\npasses=%s\nmessage=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}
help_msg() {
  printf '%s' "Comment one of: \`$TRIGGER code\` (judges only) · \`$TRIGGER functional\` (+ browser test) · \`$TRIGGER native\` (+ Anthropic's code-review plugin) · \`$TRIGGER all\`. Combine them in ONE comment — \`$TRIGGER code functional\` runs both passes in a single review; separate comments queue up and post separate reviews. Add \`deep\` to force the dual-judge review on a PR the size gate would otherwise review lightly."
}

# First line only, and only when the body starts with the trigger — otherwise a
# comment quoting the docs would trigger real runs.
FIRST_LINE=${BODY%%$'\n'*}
FIRST_LINE=${FIRST_LINE#"${FIRST_LINE%%[![:space:]]*}"}   # ltrim
FIRST_LINE=${FIRST_LINE%$'\r'}                            # CRLF-safe

# Manual dispatch with no command: the click IS the opt-in, and a menu posted to
# nobody would be a dead end.
if [ "$EVENT" = "workflow_dispatch" ] && [ -z "${FIRST_LINE//[[:space:]]/}" ]; then
  emit "run" "false" "off" "false" "code" ""
  exit 0
fi

case "$FIRST_LINE" in
  "$TRIGGER") ARGS="" ;;
  "$TRIGGER "*) ARGS="${FIRST_LINE#"$TRIGGER" }" ;;
  *)
    emit "ignore" "false" "off" "false" "" "Not a $TRIGGER command."
    exit 0
    ;;
esac

run_functional=false
native_review=off
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
    native|anthropic|plugin)       native_review=on;    add_pass native ;;
    all|everything)                run_functional=true; native_review=on
                                   add_pass code; add_pass functional; add_pass native ;;
    deep|full)                     force_deep=true;     add_pass deep ;;
    help|\?)
      emit "help" "false" "off" "false" "" "$(help_msg)"
      exit 0
      ;;
    *)
      emit "unknown" "false" "off" "false" "" "Unknown option \`$tok\`. $(help_msg)"
      exit 0
      ;;
  esac
done

# Bare `/review` prints the menu rather than guessing which pass you meant.
if [ -z "$passes" ]; then
  emit "help" "false" "off" "false" "" "$(help_msg)"
  exit 0
fi

# The judges always run, so `code` heads the list however the comment was phrased.
rest=""
for p in $passes; do [ "$p" = code ] || rest="${rest:+$rest }$p"; done
passes="code${rest:+ $rest}"

emit "run" "$run_functional" "$native_review" "$force_deep" "$passes" ""
