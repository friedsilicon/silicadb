#!/bin/sh
# Claude Code Stop hook: if protocol/storage/architecture files changed this
# session but DECISIONS.md did not, block the stop once and ask for a log
# entry (or an explicit "no decision made").

input=$(cat)

# Never loop: if we already blocked once, let the stop through.
case "$input" in
*'"stop_hook_active":true'*) exit 0 ;;
esac

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

changed=$(git status --porcelain -- src SPEC.md Makefile 2>/dev/null)
dlog=$(git status --porcelain -- DECISIONS.md 2>/dev/null)

if [ -n "$changed" ] && [ -z "$dlog" ]; then
    cat <<'EOF'
{"decision":"block","reason":"src/, SPEC.md, or Makefile changed but DECISIONS.md was not touched. If this session made a decision that shapes protocol, storage, or architecture, append a dated D-NNN entry to DECISIONS.md (format described at its top). If no such decision was made, state that briefly and finish."}
EOF
fi
exit 0
