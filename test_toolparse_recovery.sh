#!/bin/bash
# Regression tests for toolparse_recovery.sh (self-contained).
# Run: bash test_toolparse_recovery.sh
#
# Covers the three detection signatures and the configurable token file:
#   (1) a configured leaked token on its own line
#   (2) a structural anomaly: stop_reason=tool_use with no tool_use block
#   (3) the harness "could not be parsed (retry also failed)" giveup line + stop_sequence
#   plus: recovered logging, config-file tokens, and built-in fallback.
# State/logs are isolated via a temp CLAUDE_CONFIG_DIR + unique session ids, so this never
# touches the real ~/.claude state.
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/toolparse_recovery.sh"
SHIPPED_TOKENS="$(cd "$(dirname "$0")" && pwd)/toolparse_recovery.tokens"
GIVEUP="The model's tool call could not be parsed (retry also failed)."
PASS=0; FAIL=0

# Isolate state. CLAUDE_CONFIG_DIR has no tokens file -> signature (1) uses built-in defaults.
TMPD=$(mktemp -d)
export CLAUDE_CONFIG_DIR="$TMPD"
unset CLAUDE_TOOLPARSE_TOKENS 2>/dev/null || true
trap 'rm -rf "$TMPD" /tmp/claude-toolparse-retry-cctest-* 2>/dev/null' EXIT

# fixtures
T_STOP="$TMPD/stopseq.jsonl"      # stop_reason=stop_sequence (harness gave up)
T_END="$TMPD/endturn.jsonl"       # stop_reason=end_turn (a normal reply)
T_TOOLUSE="$TMPD/tooluse.jsonl"   # stop_reason=tool_use but no tool_use block
jq -nc --arg m "$GIVEUP" '{type:"assistant",message:{role:"assistant",stop_reason:"stop_sequence",content:[{type:"text",text:$m}]}}' > "$T_STOP"
jq -nc --arg m "$GIVEUP" '{type:"assistant",message:{role:"assistant",stop_reason:"end_turn",content:[{type:"text",text:$m}]}}' > "$T_END"
jq -nc '{type:"assistant",message:{role:"assistant",stop_reason:"tool_use",content:[{type:"text",text:"county"}]}}' > "$T_TOOLUSE"

run() { # name expect(block|noblock) input_json [tokens_file]
  local name="$1" expect="$2" input="$3" tok="${4:-}" out got=noblock
  if [ -n "$tok" ]; then
    out=$(printf '%s' "$input" | CLAUDE_TOOLPARSE_TOKENS="$tok" "$HOOK" 2>/dev/null)
  else
    out=$(printf '%s' "$input" | "$HOOK" 2>/dev/null)
  fi
  printf '%s' "$out" | grep -qE '"decision":[[:space:]]*"block"' && got=block
  if [ "$got" = "$expect" ]; then
    printf 'PASS: %s\n' "$name"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s (expect=%s got=%s) out=%s\n' "$name" "$expect" "$got" "$out"; FAIL=$((FAIL+1))
  fi
  rm -f /tmp/claude-toolparse-retry-cctest-* 2>/dev/null
}

# (1) built-in default token "county" on its own line -> block
run "T1 leakword-county(default)" block \
  "$(jq -nc '{session_id:"cctest-county",cwd:"/tmp",last_assistant_message:"county",transcript_path:""}')"

# (2) built-in default token "court" on its own line -> block
run "T2 leakword-court(default)" block \
  "$(jq -nc '{session_id:"cctest-court",cwd:"/tmp",last_assistant_message:"court",transcript_path:""}')"

# (3) giveup line + stop_sequence transcript -> block (signature 3)
run "T3 giveup+stop_sequence" block \
  "$(jq -nc --arg m "$GIVEUP" --arg t "$T_STOP" '{session_id:"cctest-stop",cwd:"/tmp",last_assistant_message:$m,transcript_path:$t}')"

# (4) full giveup text but end_turn (a real reply that quotes the whole line) -> no block
run "T4 giveup+end_turn(quote-only)" noblock \
  "$(jq -nc --arg m "$GIVEUP" --arg t "$T_END" '{session_id:"cctest-end",cwd:"/tmp",last_assistant_message:$m,transcript_path:$t}')"

# (5) giveup line + no readable transcript -> whole-message match only (safe fallback) -> block
run "T5 giveup+no-transcript(fallback)" block \
  "$(jq -nc --arg m "$GIVEUP" '{session_id:"cctest-fb",cwd:"/tmp",last_assistant_message:$m,transcript_path:""}')"

# (6) normal text -> no block
run "T6 normal-text" noblock \
  "$(jq -nc '{session_id:"cctest-normal",cwd:"/tmp",last_assistant_message:"完了しました。実地テスト済みです。",transcript_path:""}')"

# (7) giveup line quoted mid-sentence -> not a whole-line match -> no block (false-positive guard)
run "T7 giveup-quoted-in-longer-text" noblock \
  "$(jq -nc --arg m "なお、画面に出た $GIVEUP は無害です。" --arg t "$T_STOP" '{session_id:"cctest-quote",cwd:"/tmp",last_assistant_message:$m,transcript_path:$t}')"

# (8) structural: stop_reason=tool_use, no tool_use block -> block (token-independent)
run "T8 structural-tool_use-no-block" block \
  "$(jq -nc --arg t "$T_TOOLUSE" '{session_id:"cctest-struct",cwd:"/tmp",last_assistant_message:"county",transcript_path:$t}')"

# (9) token leaked mid-sentence (not a lone line) -> no block (false-positive guard)
run "T9 county-inline-not-lone-line" noblock \
  "$(jq -nc '{session_id:"cctest-inline",cwd:"/tmp",last_assistant_message:"Fairfax county のデータを集計しました。",transcript_path:""}')"

# (10) shipped tokens file is loaded and detects county -> block
run "T10 shipped-tokens-file" block \
  "$(jq -nc '{session_id:"cctest-shipped",cwd:"/tmp",last_assistant_message:"county",transcript_path:""}')" \
  "$SHIPPED_TOKENS"

# (11) custom tokens file (replace semantics): a custom token is detected...
CUSTOM="$TMPD/custom.tokens"
printf '%s\n' '# custom' 'banana' > "$CUSTOM"
run "T11a custom-token-detected" block \
  "$(jq -nc '{session_id:"cctest-custom1",cwd:"/tmp",last_assistant_message:"banana",transcript_path:""}')" \
  "$CUSTOM"
# ...and a default token NOT listed in the custom file is no longer detected (replace, not merge)
run "T11b custom-replaces-defaults" noblock \
  "$(jq -nc '{session_id:"cctest-custom2",cwd:"/tmp",last_assistant_message:"court",transcript_path:""}')" \
  "$CUSTOM"

# (12) block then a clean reply -> recovered event logged (success signal)
TLOG="$TMPD/recover.log"
rm -f "/tmp/claude-toolparse-retry-cctest-recover" 2>/dev/null
printf '%s' "$(jq -nc '{session_id:"cctest-recover",cwd:"/tmp",last_assistant_message:"county",transcript_path:""}')" \
  | CLAUDE_TOOLPARSE_LOG="$TLOG" "$HOOK" >/dev/null 2>&1
printf '%s' "$(jq -nc '{session_id:"cctest-recover",cwd:"/tmp",last_assistant_message:"完了しました。",transcript_path:""}')" \
  | CLAUDE_TOOLPARSE_LOG="$TLOG" "$HOOK" >/dev/null 2>&1
if grep -q '"event":"recovered"' "$TLOG" 2>/dev/null; then
  printf 'PASS: T12 recovered-event-logged\n'; PASS=$((PASS+1))
else
  printf 'FAIL: T12 recovered-event-logged (log=%s)\n' "$(cat "$TLOG" 2>/dev/null)"; FAIL=$((FAIL+1))
fi
rm -f "/tmp/claude-toolparse-retry-cctest-recover" 2>/dev/null

# (13) a clean reply with no prior block -> no spurious recovered
TLOG2="$TMPD/norecover.log"
rm -f "/tmp/claude-toolparse-retry-cctest-clean" 2>/dev/null
printf '%s' "$(jq -nc '{session_id:"cctest-clean",cwd:"/tmp",last_assistant_message:"完了しました。",transcript_path:""}')" \
  | CLAUDE_TOOLPARSE_LOG="$TLOG2" "$HOOK" >/dev/null 2>&1
if grep -q '"event":"recovered"' "$TLOG2" 2>/dev/null; then
  printf 'FAIL: T13 no-spurious-recovered (log=%s)\n' "$(cat "$TLOG2" 2>/dev/null)"; FAIL=$((FAIL+1))
else
  printf 'PASS: T13 no-spurious-recovered\n'; PASS=$((PASS+1))
fi

printf '\n=== RESULT: PASS=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
