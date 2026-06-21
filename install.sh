#!/usr/bin/env bash
# Installer for cchook-toolparse-recovery.
#
#   ./install.sh              install the Stop hook into ~/.claude/settings.json
#   ./install.sh --uninstall  remove it (the hook script file is left in place)
#
# Honours CLAUDE_CONFIG_DIR (defaults to ~/.claude). settings.json is backed up before edit.
set -euo pipefail

HOOK_NAME="toolparse_recovery.sh"
TOKENS_NAME="toolparse_recovery.tokens"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CONFIG_DIR/hooks"
SETTINGS="$CONFIG_DIR/settings.json"
DEST="$HOOKS_DIR/$HOOK_NAME"
TOKENS_DEST="$CONFIG_DIR/$TOKENS_NAME"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (https://jqlang.github.io/jq/)" >&2; exit 1; }

backup() {
  if [ -f "$SETTINGS" ]; then
    local b="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$b"
    echo "backed up settings to $b"
  fi
}

uninstall() {
  if [ ! -f "$SETTINGS" ]; then echo "no settings.json; nothing to do"; exit 0; fi
  if ! jq -e --arg n "$HOOK_NAME" '[.hooks.Stop[]?.hooks[]?.command] | any(test($n))' "$SETTINGS" >/dev/null 2>&1; then
    echo "hook not present in settings.json; nothing to remove"
    exit 0
  fi
  backup
  local tmp; tmp="$(mktemp)"
  # Drop any command that references this hook, then drop now-empty Stop groups.
  jq --arg n "$HOOK_NAME" '
    .hooks.Stop = ((.hooks.Stop // [])
      | map(.hooks |= map(select((.command // "") | test($n) | not)))
      | map(select((.hooks | length) > 0)))
    | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "removed $HOOK_NAME from Stop hooks"
  echo "(left $DEST and $TOKENS_DEST in place; delete them manually if you want)"
  echo "Open /hooks once or restart Claude Code to reload."
}

install() {
  mkdir -p "$HOOKS_DIR"
  cp "$SCRIPT_DIR/$HOOK_NAME" "$DEST"
  chmod +x "$DEST"
  echo "installed hook -> $DEST"

  # Leak-token config file: copy the defaults only if absent, so a customized file is kept.
  if [ -f "$TOKENS_DEST" ]; then
    echo "kept existing token file $TOKENS_DEST"
  else
    cp "$SCRIPT_DIR/$TOKENS_NAME" "$TOKENS_DEST"
    echo "installed default token file -> $TOKENS_DEST"
  fi

  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

  # Idempotency: skip if any Stop command already references this hook.
  if jq -e --arg n "$HOOK_NAME" '[.hooks.Stop[]?.hooks[]?.command] | any(test($n))' "$SETTINGS" >/dev/null 2>&1; then
    echo "already wired into settings.json; nothing to change"
    return
  fi

  backup
  local tmp; tmp="$(mktemp)"
  # Append a new Stop group (all Stop groups run, so this never clobbers existing hooks).
  jq --arg d "$DEST" '
    .hooks = (.hooks // {})
    | .hooks.Stop = ((.hooks.Stop // []) + [{"hooks":[{"type":"command","command":$d}]}])
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "wired into Stop hooks in $SETTINGS"
  echo "Open /hooks once or restart Claude Code to load the hook."
}

case "${1:-}" in
  --uninstall|-u) uninstall ;;
  ""|--install)   install ;;
  *) echo "usage: $0 [--install | --uninstall]" >&2; exit 2 ;;
esac
