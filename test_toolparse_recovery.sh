#!/bin/bash
# Regression tests for toolparse_recovery.sh (self-contained).
# Run: bash test_toolparse_recovery.sh
#
# Covers the two detection signatures the hook implements:
#   (1) a known leaked token on its own line (LEAK_WORDS_RE)
#   (2) a structural anomaly: stop_reason=tool_use with no tool_use block
# State and logs are isolated via a temp CLAUDE_CONFIG_DIR and unique session ids,
# so running this never touches the real ~/.claude state.
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/toolparse_recovery.sh"
PASS=0; FAIL=0

# Isolate log output (hook writes to $CLAUDE_CONFIG_DIR/logs/...).
TMPD=$(mktemp -d)
export CLAUDE_CONFIG_DIR="$TMPD"
trap 'rm -rf "$TMPD" /tmp/claude-toolparse-retry-cctest-* 2>/dev/null' EXIT

# fixtures: an assistant transcript with stop_reason=tool_use but no tool_use block,
# and a normal end_turn transcript.
T_TOOLUSE="$TMPD/tooluse.jsonl"
T_ENDTURN="$TMPD/endturn.jsonl"
jq -nc '{type:"assistant",message:{role:"assistant",stop_reason:"tool_use",content:[{type:"text",text:"county"}]}}' > "$T_TOOLUSE"
jq -nc '{type:"assistant",message:{role:"assistant",stop_reason:"end_turn",content:[{type:"text",text:"done"}]}}' > "$T_ENDTURN"

run() { # name expect(block|noblock) input_json
  local name="$1" expect="$2" input="$3" out got=noblock
  out=$(printf '%s' "$input" | "$HOOK" 2>/dev/null)
  printf '%s' "$out" | grep -qE '"decision":[[:space:]]*"block"' && got=block
  if [ "$got" = "$expect" ]; then
    printf 'PASS: %s\n' "$name"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s (expect=%s got=%s) out=%s\n' "$name" "$expect" "$got" "$out"; FAIL=$((FAIL+1))
  fi
  rm -f /tmp/claude-toolparse-retry-cctest-* 2>/dev/null
}

# (1) NEW: leaked token "county" on its own line -> block (issue #002)
run "T1 leakword-county" block \
  "$(jq -nc '{session_id:"cctest-county",cwd:"/tmp",last_assistant_message:"county",transcript_path:""}')"

# (2) existing leaked token "court" on its own line -> block (regression)
run "T2 leakword-court" block \
  "$(jq -nc '{session_id:"cctest-court",cwd:"/tmp",last_assistant_message:"court",transcript_path:""}')"

# (3) normal text -> no block
run "T3 normal-text" noblock \
  "$(jq -nc '{session_id:"cctest-normal",cwd:"/tmp",last_assistant_message:"完了しました。実地テスト済みです。",transcript_path:""}')"

# (4) structural: stop_reason=tool_use, no tool_use block -> block (regardless of token)
run "T4 structural-tool_use-no-block" block \
  "$(jq -nc --arg t "$T_TOOLUSE" '{session_id:"cctest-struct",cwd:"/tmp",last_assistant_message:"county",transcript_path:$t}')"

# (5) clean end_turn transcript with benign text -> no block (no false positive)
run "T5 clean-end_turn" noblock \
  "$(jq -nc --arg t "$T_ENDTURN" '{session_id:"cctest-clean",cwd:"/tmp",last_assistant_message:"done",transcript_path:$t}')"

# (6) leaked token embedded mid-sentence (not a lone line) -> no block (false-positive guard)
run "T6 county-inline-not-lone-line" noblock \
  "$(jq -nc '{session_id:"cctest-inline",cwd:"/tmp",last_assistant_message:"Fairfax county のデータを集計しました。",transcript_path:""}')"

printf '\n=== RESULT: PASS=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
