#!/bin/bash
# Sinapsis Observer - v4.1
# Writes one JSONL line per tool use to observations.jsonl
# Requires: python3
# Called by settings.json hooks as:
#   PreToolUse:  bash ~/.claude/skills/sinapsis-learning/hooks/observe.sh pre
#   PostToolUse: bash ~/.claude/skills/sinapsis-learning/hooks/observe.sh post

HOOK_PHASE="${1:-post}"

# Read stdin
INPUT_JSON=$(cat)
[ -z "$INPUT_JSON" ] && exit 0

# Skip if disabled
[ -f "$HOME/.claude/homunculus/disabled" ] && exit 0

# Skip non-interactive entrypoints
case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in
  cli|sdk|api|claude-desktop|"") ;;
  *) exit 0 ;;
esac

[ "${ECC_HOOK_PROFILE:-standard}" = "minimal" ] && exit 0
[ "${ECC_SKIP_OBSERVE:-0}" = "1" ] && exit 0

# Find Python — validate --version before accepting a command (aligned with PR #24).
# On Windows, `python3` is often the Microsoft Store alias shim: it answers
# `command -v` but does NOT execute (prints a notice and exits non-zero). Without
# validation, observe.sh accepted the shim and the observer failed silently.
# `py -3` (the real Windows launcher) is tried first; it does not exist on
# macOS/Linux, so the loop falls through to the real python3 there.
# The check is "Python 3." (any minor): the shim never prints that, and pinning
# minors (as PR #24 did with 3.9-3.13) silently breaks on Python 3.14+.
PYTHON_CMD=""
for candidate in "py -3" python3 python python3.13 python3.12 python3.11; do
  cmd=$(echo "$candidate" | awk '{print $1}')
  if command -v "$cmd" >/dev/null 2>&1; then
    if $candidate --version 2>&1 | grep -qE "Python 3\."; then
      PYTHON_CMD="$candidate"
      break
    fi
  fi
done
[ -z "$PYTHON_CMD" ] && exit 0

# Run the observer ($PYTHON_CMD unquoted: "py -3" is two words)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "$INPUT_JSON" | $PYTHON_CMD "$SCRIPT_DIR/observe_v3.py" "$HOOK_PHASE"

exit 0
