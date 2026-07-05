# cchook-recovery

A [Claude Code](https://code.claude.com) **Stop hook** that automatically recovers when the
model emits a **malformed / unparseable `tool_use` block** — the failure mode where the tool
never runs, the assistant goes silent mid-task, and a stray token (e.g. `court` / `county` /
`course` / `call`) leaks into the visible text.

Instead of you having to notice the stall and manually type *"continue"*, this hook detects
the corruption at turn end and nudges Claude to retry the interrupted tool call — with a
two-level safety guard so it never loops forever.

## The problem

Opus 4.7/4.8 intermittently produce a malformed `tool_use` block. The harness rejects the
whole turn with *"The model's tool call could not be parsed (retry also failed)"*, discarding
the accompanying text too, so the assistant simply stops. Two observable symptoms:

- a **lone leaked token** on its own line (`court`, `county`, `course`, `call`, …) next to
  orphaned tool arguments (`true`, an integer, `completed`, …); and/or
- the API-contract violation **`stop_reason: tool_use` with no `tool_use` block**; and/or
- the harness **giveup line** *"The model's tool call could not be parsed (retry also
  failed)."* left at the end of the turn.

This is a known, still-open issue. References:
[#63604](https://github.com/anthropics/claude-code/issues/63604) (malformed tool_use, whole
response discarded), [#61133](https://github.com/anthropics/claude-code/issues/61133)
(`stop_reason: tool_use` without a tool_use block),
[#33906](https://github.com/anthropics/claude-code/issues/33906) /
[#40462](https://github.com/anthropics/claude-code/issues/40462) (silent stalls that a manual
*"continue"* unsticks).

## How it works

At every `Stop`, the hook reads the last assistant message and triggers if **any** of:

1. **Leaked-token detection** — a known token appears alone on a line. This is the cheap,
   empirically reliable fast path. The token list lives in a config file, so new tokens are a
   one-line edit — no need to touch the script (see [Configuration](#configuration)).
2. **Structural detection** — the last assistant turn has `stop_reason: tool_use` but contains
   **no** `tool_use` block (cf. #61133). This is token-agnostic: it catches malformed tool_use
   no matter which word leaked, so you don't have to play whack-a-mole. If the transcript
   can't be read, it silently falls back to (1).
3. **Giveup-line detection** — the whole last message is exactly the harness *"…could not be
   parsed (retry also failed)."* line **and** `stop_reason: stop_sequence` (the end-of-turn
   marker the harness appends after its own retry failed). The whole-line + `stop_sequence`
   guard avoids false positives when that sentence is merely quoted inside a real reply.

On a trigger it returns:

```json
{ "decision": "block", "reason": "Please continue." }
```

which makes Claude resume the interrupted tool call in the same turn. (For the giveup-line
trigger the `reason` is a slightly longer instruction to redo the tool call in the correct
format.)

### Dual safety guard (no infinite loops)

| Knob | Default | Meaning |
|------|---------|---------|
| `MAX` | `3` | Consecutive retries for the **same** leaked fragment (one incident). |
| `HARD_MAX` | `8` | Absolute retries **per session**, accumulating even as the fragment changes. |
| `BACKOFF_SEC` | `2` | Short pause before nudging; helps if the corruption was transient. `0` disables. |

The per-incident counter **resets when the leaked fragment changes** (the model moved on to a
different action = progress), so a fresh corruption never inherits a previous one's count. All
state **resets on any clean stop**. If a limit is hit, the hook stops nudging and asks you to
type *"continue"* manually.

## Requirements

- [Claude Code](https://code.claude.com)
- [`jq`](https://jqlang.github.io/jq/)
- `bash`

## Install

### Option A — installer (recommended)

```sh
git clone https://github.com/feedtailor/cchook-recovery.git
cd cchook-recovery
./install.sh
```

The installer copies the hook to `~/.claude/hooks/`, makes it executable, installs the default
leak-token file to `~/.claude/hooks/toolparse_recovery.tokens` (only if absent, so your edits are
kept), and adds the hook to the `Stop` hooks in `~/.claude/settings.json` (backing the file up
first, and skipping if already installed). It honours `CLAUDE_CONFIG_DIR` if you use a custom
config dir.

To remove it:

```sh
./install.sh --uninstall
```

### Option B — manual

1. Copy the hook and make it executable:

   ```sh
   mkdir -p ~/.claude/hooks
   cp toolparse_recovery.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/toolparse_recovery.sh
   cp toolparse_recovery.tokens ~/.claude/hooks/  # default leak-token list (optional but recommended)
   ```

2. Add it to the `Stop` hooks in `~/.claude/settings.json` (merge with any existing hooks):

   ```json
   {
     "hooks": {
       "Stop": [
         {
           "hooks": [
             { "type": "command", "command": "~/.claude/hooks/toolparse_recovery.sh" }
           ]
         }
       ]
     }
   }
   ```

After installing, **restart Claude Code or open `/hooks` once** so the new hook is loaded.

## Configuration

### Leak tokens (config file)

Signature (1)'s token list is read from a plain-text file, **one token per line** (`#` comments
and blank lines ignored). Tokens are matched **literally**, **case-insensitively**, and only
when they appear **alone on a line** — so a token used mid-sentence never triggers a false
positive. Default path (honours `CLAUDE_CONFIG_DIR`):

```
~/.claude/hooks/toolparse_recovery.tokens
```

Add a newly observed leaked token by appending a line — no need to edit the script:

```
# ~/.claude/hooks/toolparse_recovery.tokens
court
county
course
cource
call
yournewtoken
```

The file is the single source of truth (it **replaces**, not merges with, the defaults). If it
is missing or empty, the hook falls back to the built-in defaults baked into the script, so
recovery always works even without the file.

### Other knobs

- Tune `MAX`, `HARD_MAX`, `BACKOFF_SEC` at the top of the script.
- **Kill switch:** set `CLAUDE_NO_TOOLPARSE_RECOVERY=1` to disable without uninstalling.
- `CLAUDE_TOOLPARSE_TOKENS=<path>` overrides the token file path.
- `CLAUDE_TOOLPARSE_LOG=<path>` overrides the log file path (mainly for tests).

### Tests

```sh
bash test_toolparse_recovery.sh
```

A self-contained regression suite covering all three signatures, the config-file/fallback
behaviour, the false-positive guards, and `recovered` logging. It isolates its state in a temp
config dir, so running it never touches your real `~/.claude`.

## Logs

Each trigger appends one JSONL line to `~/.claude/logs/toolparse_recovery.log`:

```json
{"ts":"…","event":"block","session":"…","cwd":"…","count":1,"total":1,"fragment":"call\n…"}
```

`event` is `block` (a nudge was sent), `recovered` (the corruption cleared after one or more
blocks — a success), or `limit` (gave up at the guard). `count` is the per-incident consecutive
count, `total` the per-session cumulative count. Quick analysis (no `cat` needed):

```sh
jq -r .cwd ~/.claude/logs/toolparse_recovery.log | sort | uniq -c | sort -rn   # by project
jq 'select(.event=="limit")' ~/.claude/logs/toolparse_recovery.log             # give-ups only
# success rate = recovered / (recovered + limit)
jq -r .event ~/.claude/logs/toolparse_recovery.log | sort | uniq -c            # event tally
```

## Known limitation

In a **"silent tool stop"** — the assistant stops right after a tool result with *no* text at
all — the `Stop` hook itself does **not** fire
([#29881](https://github.com/anthropics/claude-code/issues/29881),
[#3113](https://github.com/anthropics/claude-code/issues/3113)). This hook cannot help in that
case; that corruption mode is outside what a Stop hook can observe.

## Prior art & how this differs

Auto-continue via a Stop hook (`decision: block` + a re-injected nudge, plus an iteration cap)
is established. See Anthropic's official
[ralph-wiggum](https://github.com/anthropics/claude-code/blob/main/plugins/ralph-wiggum/hooks/stop-hook.sh)
plugin, [trailofbits/claude-code-config](https://github.com/trailofbits/claude-code-config),
and [andylizf/nonstop](https://github.com/andylizf/nonstop). Those decide *"is the work
finished?"* semantically.

What's different here is the **trigger**: this hook detects **protocol-level `tool_use`
corruption** (leaked tokens / `stop_reason: tool_use` without a tool_use block / the harness
giveup line) and recovers with a minimal *"continue"* nudge plus a per-incident + per-session
dual cap and backoff. As of writing, no existing tool targets that specific failure mode.

## License

[MIT](./LICENSE)
