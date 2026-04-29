#!/usr/bin/env bash
# phase-timing.sh — minimal stopwatch sourced by workflow steps that want timing.
#
# Usage:
#   source .review-scripts/phase-timing.sh
#   phase_start context
#   ... do work ...
#   phase_end context
#
# Each call to phase_end logs `::notice::phase=<name> duration=<n>s` and
# appends `<name>=<n>s` to /tmp/phase-summary.txt. post-review.sh reads
# that file and surfaces a one-line footer in the review body.

phase_start() {
  local name="$1"
  [ -z "$name" ] && return 0
  date +%s > "/tmp/phase-${name}.start"
}

phase_end() {
  local name="$1"
  [ -z "$name" ] && return 0
  local start_file="/tmp/phase-${name}.start"
  [ -f "$start_file" ] || return 0
  local start end dur
  start=$(cat "$start_file" 2>/dev/null) || return 0
  end=$(date +%s)
  dur=$(( end - start ))
  echo "::notice::phase=${name} duration=${dur}s"
  echo "${name}=${dur}s" >> /tmp/phase-summary.txt
  rm -f "$start_file"
}
