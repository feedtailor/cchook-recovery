#!/bin/bash
# cchook-toolparse-recovery
# A Claude Code "Stop" hook that auto-recovers from malformed / unparseable tool_use turns.
#
# Background:
#   Opus 4.7/4.8 sometimes emit a malformed tool_use block. The harness rejects the whole
#   turn ("The model's tool call could not be parsed"), so the tool never runs and the
#   assistant goes silent mid-task. A telltale sign is a stray lone token (e.g. "court" /
#   "county" / "course" / "call") leaking into the visible text alongside orphaned tool arguments.
#   See GitHub issues anthropics/claude-code#63604 and #61133.
#
# What this hook does:
#   At Stop time it inspects the last assistant message and, if it detects either
#     (1) a known leaked token on its own line, or
#     (2) a structural anomaly: stop_reason=tool_use but no tool_use block (cf. #61133),
#   it returns {"decision":"block","reason":"Please continue."} to nudge Claude to retry
#   the interrupted tool call within the same turn.
#
# Dual safety guard against infinite loops:
#   MAX       consecutive retries for the SAME leaked fragment (one incident)
#   HARD_MAX  absolute retries per session (accumulates even as the fragment changes)
#   The per-incident counter resets when the leaked fragment changes (= progress was made),
#   and the whole state resets on any clean (non-detected) stop.
#
# Environment:
#   CLAUDE_NO_TOOLPARSE_RECOVERY=1   kill switch (disable this hook)
#
# Known limitation:
#   In a "silent tool stop" (the assistant stops right after a tool result with no text at
#   all) the Stop hook does NOT fire (GitHub #29881), so this hook cannot help in that case.

set -uo pipefail

MAX=3           # consecutive retries for the same leaked fragment (one incident)
HARD_MAX=8      # absolute retries per session (runaway guard)
BACKOFF_SEC=2   # short backoff before nudging; helps if the corruption was transient. 0 disables.

# Known leaked tokens that appear on their own line. Add new ones separated by "|".
LEAK_WORDS_RE='court|county|course|cource|call'

# Kill switch
if [ "${CLAUDE_NO_TOOLPARSE_RECOVERY:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(</dev/stdin)

SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
TEXT=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""')

if [ -z "$TEXT" ] || [ "$TEXT" = "null" ]; then
  exit 0
fi

LOG_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/logs/toolparse_recovery.log"

# Append one JSONL log line: log_event <event> <count> <total> <fragment>
#   count = consecutive retries for the current fragment, total = per-session cumulative
log_event() {
  local event="$1" cnt="$2" total="$3" frag="$4"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
  mkdir -p "$(dirname "$LOG_FILE")"
  jq -nc \
    --arg ts "$ts" \
    --arg event "$event" \
    --arg session "$SESSION" \
    --arg cwd "$CWD" \
    --argjson count "$cnt" \
    --argjson total "$total" \
    --arg fragment "$frag" \
    '{ts:$ts, event:$event, session:$session, cwd:$cwd, count:$count, total:$total, fragment:$fragment}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

COUNTER_FILE="/tmp/claude-toolparse-retry-${SESSION}"

# --- Detect: (1) a leaked token on its own line, or (2) a structural anomaly ---
DETECTED=0
FRAG=""

# (1) A known leaked token appears on its own line (surrounding whitespace allowed, case-insensitive)
if printf '%s' "$TEXT" | grep -qiE "^[[:space:]]*(${LEAK_WORDS_RE})[[:space:]]*$"; then
  DETECTED=1
  FRAG=$(printf '%s' "$TEXT" | grep -iE -A3 "^[[:space:]]*(${LEAK_WORDS_RE})[[:space:]]*$" | head -n 8)
fi

# (2) Structural anomaly: the last assistant message has stop_reason=tool_use but no
#     tool_use block (#61133). This catches malformed tool_use regardless of which token
#     leaked. If the transcript cannot be read / has a different shape, skip silently and
#     fall back to (1).
if [ "$DETECTED" -eq 0 ]; then
  TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""')
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    LAST_ASST=$(jq -c 'select(.type=="assistant")' "$TRANSCRIPT" 2>/dev/null | tail -n 1 || true)
    if [ -n "$LAST_ASST" ]; then
      SR=$(printf '%s' "$LAST_ASST" | jq -r '.message.stop_reason // ""' 2>/dev/null || echo "")
      HTU=$(printf '%s' "$LAST_ASST" | jq -r '[.message.content[]? | select(.type=="tool_use")] | length' 2>/dev/null || echo "")
      if [ "$SR" = "tool_use" ] && [ "$HTU" = "0" ]; then
        DETECTED=1
        FRAG="[structural] stop_reason=tool_use but no tool_use block"
      fi
    fi
  fi
fi

if [ "$DETECTED" -eq 0 ]; then
  # No detection -> clean stop. Reset all state for the next independent incident.
  rm -f "$COUNTER_FILE" 2>/dev/null || true
  exit 0
fi

# --- Detected: read state (JSON) ---
# state = {count: consecutive retries for this fragment, total: per-session cumulative, frag: previous fragment}
STATE=$(cat "$COUNTER_FILE" 2>/dev/null || true)
[ -z "$STATE" ] && STATE='{}'
COUNT=$(printf '%s' "$STATE" | jq -r '.count // 0' 2>/dev/null || echo 0)
TOTAL=$(printf '%s' "$STATE" | jq -r '.total // 0' 2>/dev/null || echo 0)
PREV_FRAG=$(printf '%s' "$STATE" | jq -r '.frag // ""' 2>/dev/null || echo "")
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac

# New incident (the leaked fragment changed) -> reset the per-incident counter. total persists.
if [ "$FRAG" != "$PREV_FRAG" ]; then
  COUNT=0
fi

# Dual guard: give up if the same fragment hit MAX, or the session hit HARD_MAX.
if [ "$COUNT" -ge "$MAX" ] || [ "$TOTAL" -ge "$HARD_MAX" ]; then
  log_event "limit" "$COUNT" "$TOTAL" "$FRAG"
  rm -f "$COUNTER_FILE" 2>/dev/null || true
  if [ "$TOTAL" -ge "$HARD_MAX" ]; then
    printf '%s\n' '{"systemMessage":"toolparse-recovery: hit the per-session limit ('"$HARD_MAX"'). Please type \"continue\" to resume."}'
  else
    printf '%s\n' '{"systemMessage":"toolparse-recovery: hit the per-incident limit ('"$MAX"') on the same spot. Please type \"continue\" to resume."}'
  fi
  exit 0
fi

# Increment counters (count = consecutive for this fragment, total = per-session cumulative)
NEW_COUNT=$((COUNT + 1))
NEW_TOTAL=$((TOTAL + 1))
jq -nc --argjson c "$NEW_COUNT" --argjson t "$NEW_TOTAL" --arg f "$FRAG" \
  '{count:$c, total:$t, frag:$f}' > "$COUNTER_FILE"
log_event "block" "$NEW_COUNT" "$NEW_TOTAL" "$FRAG"

# Short backoff: if the corruption was transient, a brief pause may let the retry succeed.
if [ "$BACKOFF_SEC" -gt 0 ] 2>/dev/null; then
  sleep "$BACKOFF_SEC"
fi

jq -n --arg r "Please continue." '{decision:"block", reason:$r}'
exit 0
